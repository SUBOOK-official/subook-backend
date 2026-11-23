// 수거 신청 일시 중단 스위치(20261123072123)를 PGlite에서 실제로 실행해 확인한다.
// 공개 조회·관리자 전환 권한과, 중단 중 회원의 새 신청이 서버에서 거절되는지 본다.
// 운영 DB에는 접속하지 않는다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const ADMIN = '00000000-0000-0000-0000-000000000001';
const MEMBER = '00000000-0000-0000-0000-000000000002';

test('수거 신청 중단 스위치: 공개 조회, 관리자만 전환, 중단 중 회원 신청 거절', async (t) => {
  const db = new PGlite();
  const as = async (role, sub = '') => {
    await db.exec(`reset role; select set_config('request.jwt.claim.sub', '${sub}', false)`);
    if (role) await db.exec(`set role ${role}`);
  };
  const status = async () => (await db.query('select public.get_pickup_intake_status() result')).rows[0].result;
  const setPaused = async (paused) => (await db.query('select public.admin_set_pickup_intake_paused($1) result', [paused])).rows[0].result;
  const submit = () => db.query('select public.submit_pickup_stub() id');

  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role bypassrls;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
      create table public.admin_users (user_id uuid primary key);
      insert into public.admin_users values ('${ADMIN}');
      create function public.is_admin_user() returns boolean language sql stable security definer set search_path = public, auth as $$
        select exists(select 1 from public.admin_users where user_id = auth.uid());
      $$;
      create table public.pickup_requests (
        id bigint generated always as identity primary key,
        user_id uuid,
        status text not null default 'pending'
      );
      -- 운영의 신청 RPC처럼 SECURITY DEFINER 함수가 회원 대신 INSERT한다
      create function public.submit_pickup_stub() returns bigint language sql security definer set search_path = public as $$
        insert into public.pickup_requests (user_id) values (auth.uid()) returning id;
      $$;
      grant usage on schema public, auth to anon, authenticated;
    `);
    await db.exec(readFileSync(new URL('../supabase/migrations/20261123072123_pickup_intake_pause.sql', import.meta.url), 'utf8'));

    await t.test('처음에는 받는 중이고, 비로그인도 상태를 읽는다', async () => {
      await as('anon');
      const current = await status();
      assert.equal(current.paused, false);
      assert.ok(current.changed_at);
      assert.deepEqual(Object.keys(current).sort(), ['changed_at', 'paused']);
    });

    await t.test('설정 테이블은 직접 읽거나 쓸 수 없다', async () => {
      for (const [role, sub] of [['anon', ''], ['authenticated', MEMBER], ['authenticated', ADMIN]]) {
        await as(role, sub);
        await assert.rejects(db.query('select * from public.pickup_intake_settings'), /permission denied/);
        await assert.rejects(db.query('update public.pickup_intake_settings set is_paused = true'), /permission denied/);
      }
    });

    await t.test('비로그인·일반 회원은 전환할 수 없다', async () => {
      await as('anon');
      await assert.rejects(setPaused(true), /permission denied/);
      await as('authenticated', MEMBER);
      await assert.rejects(setPaused(true), /Admin access required/);
      assert.equal((await status()).paused, false);
    });

    await t.test('받는 중에는 회원 신청이 들어간다', async () => {
      await as('authenticated', MEMBER);
      assert.ok((await submit()).rows[0].id);
    });

    await t.test('관리자가 중단하면 회원의 새 신청이 거절된다', async () => {
      await as('authenticated', ADMIN);
      await assert.rejects(setPaused(null), /중단 여부/);
      const paused = await setPaused(true);
      assert.equal(paused.paused, true);

      await as('authenticated', MEMBER);
      assert.equal((await status()).paused, true);
      await assert.rejects(submit(), /수거 신청을 잠시 받지 않고 있어요/);

      await as(null);
      const settings = (await db.query('select is_paused, changed_by from public.pickup_intake_settings')).rows[0];
      assert.equal(settings.is_paused, true);
      assert.equal(settings.changed_by, ADMIN);
      assert.equal((await db.query('select count(*)::int n from public.pickup_requests')).rows[0].n, 1);
    });

    await t.test('중단 중에도 이미 접수된 신청의 변경과 서버 작업은 그대로다', async () => {
      await as(null);
      // 기존 신청 상태 변경(취소·CJ 접수 등)은 UPDATE라 막지 않는다
      assert.equal((await db.query("update public.pickup_requests set status = 'cancelled' returning id")).rows.length, 1);
      // 로그인 회원이 아닌 서버 작업의 INSERT는 통과한다
      await db.exec('insert into public.pickup_requests (user_id) values (null)');
      assert.equal((await db.query('select count(*)::int n from public.pickup_requests')).rows[0].n, 2);
    });

    await t.test('같은 값으로 다시 누르면 바뀐 시각·사람을 덮어쓰지 않는다', async () => {
      await as(null);
      await db.exec(`insert into public.admin_users values ('00000000-0000-0000-0000-000000000003')`);
      const before = (await db.query('select changed_at, changed_by from public.pickup_intake_settings')).rows[0];
      await as('authenticated', '00000000-0000-0000-0000-000000000003');
      assert.equal((await setPaused(true)).paused, true);
      await as(null);
      const after = (await db.query('select changed_at, changed_by from public.pickup_intake_settings')).rows[0];
      assert.equal(after.changed_by, ADMIN);
      assert.equal(String(after.changed_at), String(before.changed_at));
    });

    await t.test('재개하면 다시 신청이 들어간다', async () => {
      await as('authenticated', ADMIN);
      assert.equal((await setPaused(false)).paused, false);
      await as('authenticated', MEMBER);
      assert.ok((await submit()).rows[0].id);
    });

    await t.test('실행 권한: 조회는 공개, 전환은 로그인 계정만, PUBLIC 부여 없음', async () => {
      await as(null);
      const grants = async (name) => (await db.query(
        `select grantee from information_schema.routine_privileges
         where routine_schema = 'public' and routine_name = $1 order by grantee`, [name])).rows.map((row) => row.grantee);
      const read = await grants('get_pickup_intake_status');
      assert.ok(read.includes('anon') && read.includes('authenticated'));
      assert.ok(!read.includes('PUBLIC'));
      const write = await grants('admin_set_pickup_intake_paused');
      assert.ok(write.includes('authenticated'));
      assert.ok(!write.includes('anon') && !write.includes('PUBLIC'));
      const guard = await grants('block_pickup_request_while_paused');
      assert.ok(!guard.includes('anon') && !guard.includes('authenticated') && !guard.includes('PUBLIC'));
    });
  } finally {
    await db.close();
  }
});
