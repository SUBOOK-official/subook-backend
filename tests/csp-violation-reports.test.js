// CSP 위반 보고 집계(20261125165942)를 PGlite에서 실제로 실행해 확인한다.
// 같은 조합은 횟수만 오르는지, 잘못된 값·상한 초과는 버리는지, 공개 키로는 못 부르는지 본다.
// 운영 DB에는 접속하지 않는다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = readFileSync(
  new URL('../supabase/migrations/20261125165942_csp_violation_reports.sql', import.meta.url),
  'utf8',
);

const report = (overrides = {}) => JSON.stringify({
  app: 'public',
  disposition: 'report',
  directive: 'script-src-elem',
  blocked: 'https://evil.example',
  blockedUrl: 'https://evil.example/a.js',
  documentPath: '/store',
  sourceFile: 'https://subook.kr/assets/index.js',
  sample: '',
  userAgent: 'test-agent',
  ...overrides,
});

test('CSP 위반 보고: 집계, 검증, 상한, 권한', async (t) => {
  const db = new PGlite();
  const record = async (json) =>
    (await db.query('select public.record_csp_violation($1::jsonb) ok', [json])).rows[0].ok;
  const rows = async () =>
    (await db.query('select app, disposition, directive, blocked, hits, document_path from public.csp_violation_reports order by id')).rows;

  try {
    await db.exec('create role anon; create role authenticated; create role service_role bypassrls;');
    await db.exec(migration);

    await t.test('같은 조합은 한 행에 횟수만 오르고 최근 사례로 바뀐다', async () => {
      assert.equal(await record(report()), true);
      assert.equal(await record(report({ documentPath: '/cart' })), true);
      assert.deepEqual(await rows(), [{
        app: 'public', disposition: 'report', directive: 'script-src-elem',
        blocked: 'https://evil.example', hits: 2, document_path: '/cart',
      }]);
    });

    await t.test('앱·모드·막힌 출처가 다르면 다른 행이다', async () => {
      assert.equal(await record(report({ app: 'admin' })), true);
      assert.equal(await record(report({ disposition: 'enforce' })), true);
      assert.equal(await record(report({ blocked: 'inline' })), true);
      assert.equal((await rows()).length, 4);
    });

    await t.test('잘못된 값은 저장하지 않는다', async () => {
      assert.equal(await record(report({ app: 'seller' })), false);
      assert.equal(await record(report({ disposition: 'block' })), false);
      assert.equal(await record(report({ directive: 'script-src; drop table x' })), false);
      assert.equal(await record(report({ blocked: '   ' })), false);
      assert.equal(await record('[]'), false);
      assert.equal((await rows()).length, 4);
    });

    await t.test('긴 값은 잘라서 저장한다', async () => {
      assert.equal(await record(report({ blocked: `https://${'a'.repeat(400)}.example`, documentPath: `/${'p'.repeat(400)}` })), true);
      const longest = (await db.query('select max(length(blocked)) b, max(length(document_path)) d from public.csp_violation_reports')).rows[0];
      assert.equal(longest.b, 200);
      assert.equal(longest.d, 200);
    });

    await t.test('행 수 상한을 넘는 새 조합은 버리고, 기존 조합은 계속 센다', async () => {
      await db.exec(`
        insert into public.csp_violation_reports (app, disposition, directive, blocked)
        select 'public', 'report', 'img-src', 'https://filler-' || n || '.example'
        from generate_series(1, 495) n;
      `);
      assert.equal((await db.query('select count(*)::int n from public.csp_violation_reports')).rows[0].n, 500);
      assert.equal(await record(report({ blocked: 'https://one-more.example' })), false);
      assert.equal(await record(report()), true);
      assert.equal((await db.query('select count(*)::int n from public.csp_violation_reports')).rows[0].n, 500);
    });

    await t.test('90일 넘게 안 보인 행은 새 조합이 들어올 때 정리된다', async () => {
      await db.exec(`update public.csp_violation_reports set last_seen_at = now() - interval '91 days' where directive = 'img-src'`);
      assert.equal(await record(report({ blocked: 'https://fresh.example' })), true);
      assert.equal((await db.query(`select count(*)::int n from public.csp_violation_reports where directive = 'img-src'`)).rows[0].n, 0);
    });

    await t.test('공개 키·회원 권한으로는 함수도 테이블도 쓸 수 없다', async () => {
      for (const role of ['anon', 'authenticated']) {
        await db.exec(`set role ${role}`);
        await assert.rejects(() => record(report()), /permission denied/);
        await assert.rejects(() => db.query('select 1 from public.csp_violation_reports'), /permission denied/);
        await db.exec('reset role');
      }
      await db.exec('set role service_role');
      assert.equal(await record(report()), true);
      await db.exec('reset role');
    });
  } finally {
    await db.close();
  }
});
