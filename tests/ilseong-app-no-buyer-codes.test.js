// 일성월심 앱 코드를 구매자에게 내보내지 않는 migration을 PGlite PostgreSQL에서 실제로 실행한다. 운영 DB에는 접속하지 않는다.
// 앞선 migration(20261109144159 코드 발급) 위에 얹어, 구매자 쪽 읽기만 닫히고 발급 흐름은 그대로인지 본다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const read = (name) => readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8');
const baseMigration = read('20261109144159_ilseong_app_package_codes.sql');
const migration = read('20261118121612_ilseong_app_no_buyer_codes.sql');

const OWNER = '00000000-0000-0000-0000-0000000000aa';
const OTHER = '00000000-0000-0000-0000-0000000000bb';
const CODE = 'AAAA-BBBB-CCCC-DDDD';

async function setup({ withBuyerMigration = true } = {}) {
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
    -- 운영 DB의 알림 기록 제약(20260710032216)과 같은 10종
    create table notification_logs(id bigint generated always as identity primary key, notification_type text not null,
      constraint notification_logs_notification_type_check check (notification_type in (
        'pickup_accepted', 'arrived', 'inspection_done', 'sold', 'settlement_done',
        'order_confirmed', 'shipping_started', 'delivery_done', 'restock', 'refund_completed')));
    insert into notification_logs(notification_type) values ('order_confirmed'), ('arrived'), ('refund_completed');
    grant select on orders to authenticated;
    insert into products(id) values (1), (2);
    insert into books(id, product_id) values (11, 1), (12, 1), (21, 2);
  `);
  await db.exec(baseMigration);
  if (withBuyerMigration) await db.exec(migration);
  return db;
}

const one = async (db, sql, params = []) => (await db.query(sql, params)).rows[0];
const all = async (db, sql, params = []) => (await db.query(sql, params)).rows;
const asUser = (db, uid) => db.query(`select set_config('app.uid', '${uid ?? ''}', false)`);
const access = async (db, orderId) => (await one(db, 'select get_my_order_app_access($1) as r', [orderId])).r;

// 주문 100(회원 OWNER, 앱 패키지 1개 + 다른 책 1권), 주문 200(회원 OWNER, 다른 책만)을 결제 확인까지 만든다
async function paidOrders(db) {
  await db.query('select admin_set_ilseong_app_product(1, true)');
  await db.exec(`
    insert into orders(id, user_id, order_number) values (100, '${OWNER}', 'ORD-2611-0100'), (200, '${OWNER}', 'ORD-2611-0200');
    insert into order_items(id, order_id, book_id, product_id) values (501, 100, 11, 1), (502, 100, 21, 2), (601, 200, 21, 2);
  `);
  await db.query("update orders set payment_status='paid', status='preparing' where id in (100, 200)");
}

const record = (db, orderId, lines) => db.query('select ilseong_app_record_lines($1, $2::jsonb)', [orderId, JSON.stringify(lines)]);

test('구매자 읽기: 코드를 주던 함수·표 읽기 권한이 없어지고 상태만 주는 함수가 생긴다', async () => {
  const db = await setup();
  try {
    const exists = async (signature) => (await one(db, 'select to_regprocedure($1) is not null as ok', [signature])).ok;
    assert.equal(await exists('public.get_my_order_app_codes(bigint)'), false);
    assert.equal(await exists('public.get_guest_order_app_codes(text,text)'), false);
    assert.equal(await exists('public._ilseong_app_buyer_lines(bigint)'), false);
    assert.equal(await exists('public.get_my_order_app_access(bigint)'), true);

    const can = async (role, fn) => (await one(db, "select has_function_privilege($1, $2, 'execute') as ok", [role, fn])).ok;
    assert.equal(await can('anon', 'get_my_order_app_access(bigint)'), false);
    assert.equal(await can('authenticated', 'get_my_order_app_access(bigint)'), true);
    // 코드 원문을 담은 서버 전용 함수는 그대로 서버만
    for (const role of ['anon', 'authenticated']) {
      assert.equal(await can(role, 'ilseong_app_order_context(bigint)'), false, `${role} order_context`);
      assert.equal(await can(role, 'ilseong_app_record_lines(bigint,jsonb,boolean)'), false, `${role} record_lines`);
    }
    assert.equal(await can('service_role', 'ilseong_app_order_context(bigint)'), true);

    // 표: 회원도 직접 못 읽는다(권한 없음 + 정책 없음). 앱 패키지 표시는 계속 공개
    const tableCan = async (role, table) => (await one(db, "select has_table_privilege($1, $2, 'select') as ok", [role, table])).ok;
    assert.equal(await tableCan('authenticated', 'order_app_codes'), false);
    assert.equal(await tableCan('anon', 'order_app_codes'), false);
    assert.equal(await tableCan('anon', 'ilseong_app_products'), true);
    assert.equal((await one(db, "select count(*)::int n from pg_policies where tablename = 'order_app_codes'")).n, 0);
    assert.equal((await one(db, "select relrowsecurity as on from pg_class where relname = 'order_app_codes'")).on, true);

    await paidOrders(db);
    await record(db, 100, [{ lineRef: '501-1', code: CODE, status: 'ISSUED' }]);
    await asUser(db, OWNER);
    await db.exec('set role authenticated');
    await assert.rejects(db.query('select code from order_app_codes'), /permission denied/);
    // 상태 함수는 회원 권한으로 부를 수 있고 코드를 담지 않는다
    assert.deepEqual(await access(db, 100), { state: 'waiting', app_download_url: null });
    await db.exec('reset role');
  } finally {
    await db.close();
  }
});

test('앱 이용 상태: 본인 앱 패키지 주문만, 로그인 대기 → 등록됨 → 환불로 끝남, 코드는 어디에도 없다', async () => {
  const db = await setup();
  try {
    await paidOrders(db);

    // 발급 전(대기열에 있을 때)부터 안내는 보인다
    await asUser(db, OWNER);
    assert.deepEqual(await access(db, 100), { state: 'waiting', app_download_url: null });
    // 앱 패키지가 없는 주문, 남의 주문, 없는 주문, 로그인 안 함 → null
    assert.equal(await access(db, 200), null);
    assert.equal(await access(db, 999), null);
    await asUser(db, OTHER);
    assert.equal(await access(db, 100), null);
    await asUser(db, null);
    assert.equal(await access(db, 100), null);

    await record(db, 100, [{ lineRef: '501-1', code: CODE, status: 'ISSUED' }]);
    await db.query("update ilseong_app_settings set app_download_url = 'https://example.com/ilseong-app' where id = 1");
    await asUser(db, OWNER);
    const waiting = await access(db, 100);
    assert.deepEqual(waiting, { state: 'waiting', app_download_url: 'https://example.com/ilseong-app' });

    await record(db, 100, [{ lineRef: '501-1', code: CODE, status: 'REDEEMED' }]);
    const registered = await access(db, 100);
    assert.equal(registered.state, 'registered');

    // 다른 책만 환불 → 그대로
    await db.query('update order_items set refunded_at=now() where id=502');
    assert.equal((await access(db, 100)).state, 'registered');

    // 교재 환불(기본 정책: 앱 이용도 종료) → 끝남, 앱 받는 곳도 내보내지 않는다
    await db.query('update order_items set refunded_at=now() where id=501');
    const ended = await access(db, 100);
    assert.deepEqual(ended, { state: 'ended', app_download_url: null });

    for (const result of [waiting, registered, ended]) {
      const text = JSON.stringify(result);
      assert.deepEqual(Object.keys(result).sort(), ['app_download_url', 'state']);
      for (const part of CODE.split('-')) assert.equal(text.includes(part), false, `상태에 코드 조각 ${part}`);
    }
  } finally {
    await db.close();
  }
});

test('앱 이용 상태: 환불 정책이 "이미 등록한 앱 이용은 유지"면 등록한 줄은 계속 등록됨, 등록 전 줄은 끝남', async () => {
  const db = await setup();
  try {
    await db.query('select admin_set_ilseong_app_product(1, true)');
    await db.exec(`
      insert into orders(id, user_id, order_number) values (100, '${OWNER}', 'ORD-2611-0100'), (300, '${OWNER}', 'ORD-2611-0300');
      insert into order_items(id, order_id, book_id, product_id) values (501, 100, 11, 1), (701, 300, 12, 1);
    `);
    await db.query("update orders set payment_status='paid', status='preparing' where id in (100, 300)");
    await record(db, 100, [{ lineRef: '501-1', code: CODE, status: 'REDEEMED' }]);
    await record(db, 300, [{ lineRef: '701-1', code: 'GGGG-HHHH-JJJJ-KKKK', status: 'ISSUED' }]);
    await db.query("select ilseong_app_save_settings(null, 'revoke_unredeemed', null, null)");
    await db.query('update order_items set refunded_at=now() where id in (501, 701)');

    await asUser(db, OWNER);
    assert.equal((await access(db, 100)).state, 'registered');
    assert.equal((await access(db, 300)).state, 'ended');

    // 앱 서버가 폐기를 확정한 줄(revoked)은 정책과 상관없이 끝남
    await record(db, 100, [{ lineRef: '501-1', status: 'REVOKED' }]);
    assert.equal((await access(db, 100)).state, 'ended');
  } finally {
    await db.close();
  }
});

test('발급 흐름은 그대로: 결제 확인 → 줄·대기열, 서버는 코드와 주문 회원을 읽고 안내 알림을 기다린다', async () => {
  const db = await setup();
  try {
    await paidOrders(db);
    assert.deepEqual(await all(db, 'select line_ref, status, code from order_app_codes order by id'), [
      { line_ref: '501-1', status: 'pending', code: null },
    ]);
    assert.equal((await one(db, "select count(*)::int n from ilseong_app_jobs where status='pending'")).n, 1);
    const job = (await one(db, 'select ilseong_app_claim_job() as j')).j;
    assert.equal(job.order_id, 100);

    await record(db, 100, [{ lineRef: '501-1', code: CODE, status: 'ISSUED' }]);
    const context = (await one(db, 'select ilseong_app_order_context(100) as c')).c;
    assert.equal(context.order.user_id, OWNER);
    assert.equal(context.lines[0].code, CODE);
    // 안내 알림을 아직 안 보냈으면 남은 일이 있다 → 보내고 적으면 끝
    assert.equal((await one(db, 'select _ilseong_app_order_outstanding(100) as r')).r, true);
    await db.query("select ilseong_app_mark_notified(100, array['501-1'])");
    assert.equal((await one(db, 'select _ilseong_app_order_outstanding(100) as r')).r, false);
    assert.equal((await one(db, 'select ilseong_app_finish_job($1, null) as f', [job.id])).f.status, 'done');
  } finally {
    await db.close();
  }
});

test('알림 기록: app_guide를 받고, 기존 종류는 그대로, app_code·모르는 종류는 거절', async () => {
  const db = await setup();
  try {
    assert.equal((await one(db, 'select count(*)::int n from notification_logs')).n, 3, '기존 기록 유지');
    await db.query("insert into notification_logs(notification_type) values ('app_guide'), ('order_confirmed'), ('sold'), ('restock')");
    await assert.rejects(db.query("insert into notification_logs(notification_type) values ('app_code')"), /notification_logs_notification_type_check/);
    await assert.rejects(db.query("insert into notification_logs(notification_type) values ('whatever')"), /notification_logs_notification_type_check/);
  } finally {
    await db.close();
  }
});

test('적용 전 상태 대조: 이 migration 전에는 회원이 코드를 읽을 수 있었다', async () => {
  const db = await setup({ withBuyerMigration: false });
  try {
    await paidOrders(db);
    await record(db, 100, [{ lineRef: '501-1', code: CODE, status: 'ISSUED' }]);
    await asUser(db, OWNER);
    assert.equal((await one(db, 'select get_my_order_app_codes(100) as r')).r[0].code, CODE);
    await db.exec('set role authenticated');
    assert.equal((await one(db, 'select code from order_app_codes')).code, CODE);
    await db.exec('reset role');
    await assert.rejects(db.query("insert into notification_logs(notification_type) values ('app_guide')"), /notification_logs_notification_type_check/);

    // 같은 DB에 migration을 얹으면 닫힌다(운영 적용과 같은 순서)
    await db.exec(migration);
    await db.exec('set role authenticated');
    await assert.rejects(db.query('select code from order_app_codes'), /permission denied/);
    await assert.rejects(db.query('select get_my_order_app_codes(100)'), /does not exist/);
    assert.deepEqual(await access(db, 100), { state: 'waiting', app_download_url: null });
    await db.exec('reset role');
  } finally {
    await db.close();
  }
});
