// 일성월심 앱 코드 migration을 PGlite PostgreSQL에서 실제로 실행한다. 운영 DB에는 접속하지 않는다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const migration = readFileSync(new URL('../supabase/migrations/20261109144159_ilseong_app_package_codes.sql', import.meta.url), 'utf8');

const OWNER = '00000000-0000-0000-0000-0000000000aa';
const OTHER = '00000000-0000-0000-0000-0000000000bb';

async function setup() {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.uid', true), '')::uuid$$;
    create function is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('app.test_admin',true),'true')='true'$$;
    create table ops_alerts(text text);
    create function notify_ops_slack(p_text text) returns void language sql as $$insert into ops_alerts values (p_text)$$;
    create table products(id bigint primary key, title text default '일성월심', option text, status text default 'selling',
      is_listed boolean not null default true);
    -- 기존 파생 상태 트리거 흉내: 이름 순서상 게이트가 먼저
    create function products_enforce_derived_status() returns trigger language plpgsql as $$
      begin new.status := case when new.is_listed then 'selling' else 'hidden' end; return new; end $$;
    create trigger products_enforce_derived_status_trigger before insert or update of status, is_listed on products
      for each row execute function products_enforce_derived_status();
    create table books(id bigint primary key, product_id bigint references products(id));
    create table orders(id bigint primary key, user_id uuid, order_number text, status text default 'pending',
      payment_status text default 'pending', shipping_recipient_name text default '홍길동', shipping_recipient_phone text default '010-1234-5678');
    create table order_items(id bigint primary key, order_id bigint references orders(id), book_id bigint references books(id),
      product_id bigint, title text default '일성월심 학습지', quantity integer default 1, refunded_at timestamptz);
    create table direct_sale_products(product_id bigint primary key references products(id));
    create table guest_order_lookup_attempts(id bigint generated always as identity, bucket_key text, attempted_at timestamptz default now());
    grant select on orders to authenticated;
    insert into products(id) values (1), (2);
    insert into books(id, product_id) values (11, 1), (12, 1), (21, 2);
  `);
  await db.exec(migration);
  return db;
}

const one = async (db, sql, params = []) => (await db.query(sql, params)).rows[0];
const all = async (db, sql, params = []) => (await db.query(sql, params)).rows;

test('기본 꺼짐: 앱 패키지 지정 시 숨김, 판매 꺼짐이면 공개 거부, 다른 상품은 그대로', async () => {
  const db = await setup();
  try {
    assert.deepEqual(await one(db, 'select sales_enabled, refund_policy, app_download_url from ilseong_app_settings'),
      { sales_enabled: false, refund_policy: 'revoke_access', app_download_url: null });

    const marked = (await one(db, 'select admin_set_ilseong_app_product(1, true) as r')).r;
    assert.equal(marked.is_app_package, true);
    assert.equal(marked.app_product_code, 'ILSEONG_2028_SET4');
    assert.deepEqual(await one(db, 'select is_listed, status from products where id=1'), { is_listed: false, status: 'hidden' });
    assert.ok(await one(db, 'select 1 as ok from direct_sale_products where product_id=1'));

    await assert.rejects(db.query('update products set is_listed=true where id=1'), /판매가 꺼져 있어/);
    // 앱 패키지가 아닌 상품은 영향 없음
    await db.query('update products set is_listed=false where id=2');
    await db.query('update products set is_listed=true where id=2');
    assert.equal((await one(db, 'select is_listed from products where id=2')).is_listed, true);

    // 판매 켜면 공개 가능, 끄면 앱 패키지만 다시 숨김
    await db.query("select ilseong_app_save_settings(true, null, 'https://app.example.test/get', null)");
    await db.query('update products set is_listed=true where id=1');
    assert.equal((await one(db, 'select status from products where id=1')).status, 'selling');
    assert.equal((await one(db, 'select ilseong_app_disable_sales() as r')).r, true);
    assert.deepEqual(await all(db, 'select id, is_listed from products order by id'), [{ id: 1, is_listed: false }, { id: 2, is_listed: true }]);
    assert.equal((await one(db, 'select ilseong_app_disable_sales() as r')).r, false);
    // 설정 주소는 끄기에도 유지
    assert.equal((await one(db, 'select app_download_url from ilseong_app_settings')).app_download_url, 'https://app.example.test/get');

    await db.query("select set_config('app.test_admin', 'false', false)");
    await assert.rejects(db.query('select admin_set_ilseong_app_product(2, true)'), /Admin access required/);
  } finally {
    await db.close();
  }
});

test('결제 확인 → 줄 생성·대기열, 처리 성공·실패 간격·실패 경보', async () => {
  const db = await setup();
  try {
    await db.query('select admin_set_ilseong_app_product(1, true)');
    await db.exec(`
      insert into orders(id, user_id, order_number) values (100, '${OWNER}', 'ORD-2611-0100'), (200, '${OWNER}', 'ORD-2611-0200');
      insert into order_items(id, order_id, book_id, product_id, quantity) values (501, 100, 11, 1, 2), (502, 100, 21, 2, 1), (601, 200, 21, 2, 1);
    `);
    // 앱 패키지가 없는 주문: 아무것도 생기지 않는다
    await db.query("update orders set payment_status='paid', status='preparing' where id=200");
    assert.equal((await one(db, 'select count(*)::int n from order_app_codes')).n, 0);
    assert.equal((await one(db, 'select count(*)::int n from ilseong_app_jobs')).n, 0);

    await db.query("update orders set payment_status='paid', status='preparing' where id=100");
    assert.deepEqual(await all(db, 'select line_ref, unit_index, status, code from order_app_codes order by id'), [
      { line_ref: '501-1', unit_index: 1, status: 'pending', code: null },
      { line_ref: '501-2', unit_index: 2, status: 'pending', code: null },
    ]);
    // 같은 전이가 다시 와도 줄은 늘지 않는다
    await db.query("update orders set payment_status='pending' where id=100");
    await db.query("update orders set payment_status='paid' where id=100");
    assert.equal((await one(db, 'select count(*)::int n from order_app_codes')).n, 2);
    assert.equal((await one(db, "select count(*)::int n from ilseong_app_jobs where status='pending'")).n, 1);

    const job = (await one(db, 'select ilseong_app_claim_job() as j')).j;
    assert.equal(job.order_id, 100);
    assert.equal(job.attempts, 1);
    assert.equal((await one(db, 'select ilseong_app_claim_job() as j')).j, null, '잠긴 작업은 다시 가져가지 않는다');

    // 실패 → 1분 뒤, 다음 실패 → 2분 뒤
    let finished = (await one(db, "select ilseong_app_finish_job($1, '앱 서버 연결 실패') as r", [job.id])).r;
    assert.equal(finished.status, 'pending');
    const delay = async () => (await one(db, "select round(extract(epoch from next_attempt_at - now())/60) as m from ilseong_app_jobs where id=$1", [job.id])).m;
    assert.equal(Number(await delay()), 1);
    await db.query('update ilseong_app_jobs set next_attempt_at=now() where id=$1', [job.id]);
    await db.query('select ilseong_app_claim_job()');
    await db.query("select ilseong_app_finish_job($1, '또 실패')", [job.id]);
    assert.equal(Number(await delay()), 2);

    // 성공: 코드 저장 → 알림 남음 → 알림 기록 → 완료
    await db.query('update ilseong_app_jobs set next_attempt_at=now() where id=$1', [job.id]);
    await db.query('select ilseong_app_claim_job()');
    await db.query(`select ilseong_app_record_lines(100, $1::jsonb)`, [JSON.stringify([
      { lineRef: '501-1', code: 'AAAA-BBBB-CCCC-DDDD', status: 'ISSUED', issuedAt: '2026-11-09T00:00:00Z' },
      { lineRef: '501-2', code: 'EEEE-FFFF-GGGG-HHHH', status: 'ISSUED', issuedAt: '2026-11-09T00:00:00Z' },
    ])]);
    assert.equal((await one(db, 'select _ilseong_app_order_outstanding(100) as r')).r, true, '알림이 남아 있다');
    await db.query("select ilseong_app_mark_notified(100, array['501-1','501-2'])");
    finished = (await one(db, 'select ilseong_app_finish_job($1, null) as r', [job.id])).r;
    assert.equal(finished.status, 'done');

    // 12회 넘게 실패하면 failed + 운영 경보
    await db.query("insert into orders(id, order_number, payment_status, status) values (300, 'ORD-2611-G0000000300', 'pending', 'pending')");
    await db.query('insert into order_items(id, order_id, book_id, product_id) values (701, 300, 12, 1)');
    await db.query("update orders set payment_status='paid' where id=300");
    for (let i = 0; i < 12; i += 1) {
      await db.query('update ilseong_app_jobs set next_attempt_at=now() where order_id=300');
      const claimed = (await one(db, 'select ilseong_app_claim_job() as j')).j;
      assert.equal(claimed.order_id, 300);
      await db.query("select ilseong_app_finish_job($1, 'HTTP 503')", [claimed.id]);
    }
    assert.equal((await one(db, 'select status from ilseong_app_jobs where order_id=300')).status, 'failed');
    assert.match((await one(db, 'select text from ops_alerts')).text, /ORD-2611-G0000000300/);
    // 다시 시도하면 새 작업
    assert.equal((await one(db, 'select ilseong_app_retry_order(300) as r')).r, true);
    assert.equal((await one(db, "select attempts from ilseong_app_jobs where order_id=300 and status='pending'")).attempts, 0);
  } finally {
    await db.close();
  }
});

test('대기열이 깨져도 결제 확인·환불은 그대로 끝난다', async () => {
  const db = await setup();
  try {
    await db.query('select admin_set_ilseong_app_product(1, true)');
    await db.exec(`insert into orders(id, order_number) values (100, 'ORD-1');
      insert into order_items(id, order_id, book_id, product_id) values (501, 100, 11, 1);`);
    await db.exec('alter table order_app_codes rename to order_app_codes_broken');
    await db.query("update orders set payment_status='paid', status='preparing' where id=100");
    await db.query('update order_items set refunded_at=now() where id=501');
    await db.query("update orders set status='refunded' where id=100");
    assert.deepEqual(await one(db, 'select payment_status, status from orders where id=100'), { payment_status: 'paid', status: 'refunded' });
  } finally {
    await db.close();
  }
});

test('환불: 앱 패키지 줄만 폐기 요청, 굿즈만 환불이면 그대로, 정책 바꾸기·환불 복원', async () => {
  const db = await setup();
  try {
    await db.query('select admin_set_ilseong_app_product(1, true)');
    await db.exec(`
      insert into orders(id, user_id, order_number) values (100, '${OWNER}', 'ORD-2611-0100');
      insert into order_items(id, order_id, book_id, product_id, quantity) values (501, 100, 11, 1, 1), (502, 100, 21, 2, 1);
    `);
    await db.query("update orders set payment_status='paid', status='preparing' where id=100");
    await db.query("select ilseong_app_record_lines(100, $1::jsonb)", [JSON.stringify([{ lineRef: '501-1', code: 'AAAA-BBBB-CCCC-DDDD', status: 'REDEEMED' }])]);
    await db.query("select ilseong_app_mark_notified(100, array['501-1'])");
    await db.query("update ilseong_app_jobs set status='done'");

    // 굿즈(다른 상품)만 환불 → 앱 코드 그대로
    await db.query('update order_items set refunded_at=now() where id=502');
    assert.equal((await one(db, "select revoke_requested_at from order_app_codes where line_ref='501-1'")).revoke_requested_at, null);
    assert.equal((await one(db, "select count(*)::int n from ilseong_app_jobs where status='pending'")).n, 0);

    // 교재(앱 패키지) 환불 → revokeAccess 요청 + 대기열
    await db.query('update order_items set refunded_at=now() where id=501');
    const row = await one(db, "select revoke_access, revoke_requested_at is not null as requested from order_app_codes where line_ref='501-1'");
    assert.deepEqual(row, { revoke_access: true, requested: true });
    assert.equal((await one(db, "select count(*)::int n from ilseong_app_jobs where status='pending'")).n, 1);

    // 앱 서버에 보내기 전 환불 복원 → 요청 거둠
    await db.query('update order_items set refunded_at=null where id=501');
    assert.equal((await one(db, "select revoke_requested_at from order_app_codes where line_ref='501-1'")).revoke_requested_at, null);

    // 정책 none → 폐기 요청 없음, revoke_unredeemed → revokeAccess false
    await db.query("select ilseong_app_save_settings(null, 'none', null, null)");
    await db.query('update order_items set refunded_at=now() where id=501');
    assert.equal((await one(db, "select revoke_requested_at from order_app_codes where line_ref='501-1'")).revoke_requested_at, null);
    await db.query('update order_items set refunded_at=null where id=501');
    await db.query("select ilseong_app_save_settings(null, 'revoke_unredeemed', null, null)");
    await db.query("update orders set status='refunded' where id=100");
    assert.equal((await one(db, "select revoke_access from order_app_codes where line_ref='501-1'")).revoke_access, false);

    // 처리 기록: 앱 서버에 없던 발급 전 줄은 revoked
    await db.query("select ilseong_app_mark_revoke_processed(100, array['501-1'])");
    assert.equal((await one(db, 'select _ilseong_app_order_outstanding(100) as r')).r, false);
  } finally {
    await db.close();
  }
});

test('읽기 권한: 코드 원문은 주문 회원 본인·비회원 인증·서버만', async () => {
  const db = await setup();
  try {
    await db.query('select admin_set_ilseong_app_product(1, true)');
    await db.exec(`
      insert into orders(id, user_id, order_number) values (100, '${OWNER}', 'ORD-2611-0100');
      insert into orders(id, user_id, order_number, shipping_recipient_phone) values (300, null, 'ORD-2611-GABCDEFGHIJ', '010-5555-6666');
      insert into order_items(id, order_id, book_id, product_id) values (501, 100, 11, 1), (701, 300, 12, 1);
    `);
    await db.query("update orders set payment_status='paid', status='preparing' where id in (100, 300)");
    await db.query("select ilseong_app_record_lines(100, $1::jsonb)", [JSON.stringify([{ lineRef: '501-1', code: 'AAAA-BBBB-CCCC-DDDD', status: 'ISSUED' }])]);
    await db.query("select ilseong_app_record_lines(300, $1::jsonb)", [JSON.stringify([{ lineRef: '701-1', code: 'GGGG-BBBB-CCCC-DDDD', status: 'ISSUED' }])]);

    // 함수 실행 권한
    const can = async (role, fn) => (await one(db, 'select has_function_privilege($1, $2, \'execute\') as ok', [role, fn])).ok;
    for (const fn of ['ilseong_app_order_context(bigint)', 'ilseong_app_claim_job()', 'ilseong_app_save_settings(boolean,text,text,uuid)',
      'ilseong_app_record_lines(bigint,jsonb,boolean)', 'ilseong_app_admin_overview()', '_ilseong_app_buyer_lines(bigint)']) {
      assert.equal(await can('anon', fn), false, `anon ${fn}`);
      assert.equal(await can('authenticated', fn), false, `authenticated ${fn}`);
    }
    assert.equal(await can('anon', 'get_guest_order_app_codes(text,text)'), true);
    assert.equal(await can('anon', 'get_my_order_app_codes(bigint)'), false);
    assert.equal(await can('authenticated', 'get_my_order_app_codes(bigint)'), true);
    // 테이블 권한: anon은 코드·설정·대기열을 못 읽고, 앱 패키지 표시는 공개
    const tableCan = async (role, table) => (await one(db, 'select has_table_privilege($1, $2, \'select\') as ok', [role, table])).ok;
    assert.equal(await tableCan('anon', 'order_app_codes'), false);
    assert.equal(await tableCan('anon', 'ilseong_app_settings'), false);
    assert.equal(await tableCan('authenticated', 'ilseong_app_jobs'), false);
    assert.equal(await tableCan('anon', 'ilseong_app_products'), true);

    // 회원 RPC: 본인만
    await db.query(`select set_config('app.uid', '${OWNER}', false)`);
    const mine = (await one(db, 'select get_my_order_app_codes(100) as r')).r;
    assert.equal(mine[0].code, 'AAAA-BBBB-CCCC-DDDD');
    assert.equal(mine[0].state, 'issued');
    await db.query(`select set_config('app.uid', '${OTHER}', false)`);
    assert.deepEqual((await one(db, 'select get_my_order_app_codes(100) as r')).r, []);

    // 테이블 직접 읽기(RLS): 본인 주문 줄만
    await db.query(`select set_config('app.uid', '${OWNER}', false)`);
    await db.exec('set role authenticated');
    assert.deepEqual((await all(db, 'select line_ref from order_app_codes order by line_ref')).map((r) => r.line_ref), ['501-1']);
    await db.exec(`select set_config('app.uid', '${OTHER}', false)`);
    assert.deepEqual(await all(db, 'select line_ref from order_app_codes'), []);
    await db.exec('reset role');

    // 비회원: 주문번호 + 휴대폰
    const guest = (await one(db, "select get_guest_order_app_codes('ord-2611-gabcdefghij', '01055556666') as r")).r;
    assert.equal(guest.found, true);
    assert.equal(guest.lines[0].code, 'GGGG-BBBB-CCCC-DDDD');
    const wrong = (await one(db, "select get_guest_order_app_codes('ORD-2611-GABCDEFGHIJ', '01000000000') as r")).r;
    assert.deepEqual(wrong, { found: false, lines: [] });
    assert.equal((await one(db, 'select count(*)::int n from guest_order_lookup_attempts')).n, 1);
    // 회원 주문은 비회원 조회로 못 본다
    assert.equal((await one(db, "select get_guest_order_app_codes('ORD-2611-0100', '01012345678') as r")).r.found, false);

    // 환불로 끝난 코드는 원문을 내보내지 않는다
    await db.query('update order_items set refunded_at=now() where id=701');
    const ended = (await one(db, "select get_guest_order_app_codes('ORD-2611-GABCDEFGHIJ', '010-5555-6666') as r")).r;
    assert.deepEqual([ended.lines[0].state, ended.lines[0].code], ['ended', null]);
  } finally {
    await db.close();
  }
});
