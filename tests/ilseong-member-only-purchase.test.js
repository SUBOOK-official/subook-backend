// 일성월심 학습지(앱 패키지 상품)는 회원만 산다: 비회원 주문 생성 RPC가 앱 패키지 책을 거절하는지
// migration을 PGlite PostgreSQL에서 실제로 실행해 확인한다. 운영 DB에는 접속하지 않는다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const migration = readFileSync(new URL('../supabase/migrations/20261116194737_ilseong_app_member_only_purchase.sql', import.meta.url), 'utf8');

async function setup() {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create table products(id bigint primary key);
    create table books(id bigint primary key, product_id bigint references products(id));
    create table ilseong_app_products(product_id bigint primary key references products(id), app_product_code text default 'ILSEONG_2028_SET4');
    create table orders(id bigint generated always as identity primary key, user_id uuid, status text default 'pending', shipping_recipient_phone text);
    create table pg_checkout_sessions(id bigint generated always as identity primary key, order_number text, user_id uuid,
      payload jsonb, expected_amount integer, created_at timestamptz default now());
    create function generate_guest_order_number() returns text language sql as $$select 'ORD-TEST-G0000000001'$$;
    -- 실제 주문 생성 대신: 불렸다는 것과 받은 책만 돌려준다
    create function create_order_core(
      p_user_id uuid, p_book_ids bigint[], p_quantities integer[], p_shipping_recipient_name text, p_shipping_recipient_phone text,
      p_shipping_postal_code text, p_shipping_address_line1 text, p_shipping_address_line2 text, p_shipping_memo text,
      p_payment_method text default 'bank_transfer', p_member_coupon_id bigint default null, p_refund_bank text default null,
      p_refund_account_number text default null, p_refund_account_holder text default null, p_order_number text default null,
      p_validate_only boolean default false, p_is_guest boolean default false
    ) returns jsonb language sql as $$
      select jsonb_build_object('core_called', true, 'book_ids', to_jsonb(p_book_ids), 'guest', p_is_guest, 'total_amount', 1000)
    $$;
    insert into products(id) values (1), (2);
    insert into books(id, product_id) values (11, 1), (12, 1), (21, 2);
    insert into ilseong_app_products(product_id) values (2);  -- 상품 2 = 일성월심 학습지
  `);
  await db.exec(migration);
  return db;
}

const guestOrder = (db, books) => db.query(
  "select create_guest_order($1::bigint[], $2::integer[], '홍길동', '010-1234-5678', '12345', '주소', null, null, null, null, null, true) as r",
  [books, books.map(() => 1)],
);
const guestCard = (db, books) => db.query(
  "select create_guest_pg_checkout_session($1::bigint[], $2::integer[], '홍길동', '010-1234-5678', '12345', '주소', null, null, true) as r",
  [books, books.map(() => 1)],
);

test('다른 교재는 비회원도 그대로 주문한다(무통장·카드)', async () => {
  const db = await setup();
  try {
    const bank = (await guestOrder(db, [11, 12])).rows[0].r;
    assert.equal(bank.core_called, true);
    assert.equal(bank.guest, true);
    const card = (await guestCard(db, [11])).rows[0].r;
    assert.equal(card.checkout_session, true);
    assert.equal((await db.query('select count(*)::int as n from pg_checkout_sessions')).rows[0].n, 1);
  } finally {
    await db.close();
  }
});

test('일성월심 학습지가 하나라도 담기면 비회원 주문을 거절한다(무통장·카드), 결제 세션도 만들지 않는다', async () => {
  const db = await setup();
  try {
    await assert.rejects(guestOrder(db, [21]), /일성월심 학습지는 회원만 구매할 수 있어요/);
    await assert.rejects(guestOrder(db, [11, 21]), /일성월심 학습지는 회원만 구매할 수 있어요/);
    await assert.rejects(guestCard(db, [21]), /일성월심 학습지는 회원만 구매할 수 있어요/);
    assert.equal((await db.query('select count(*)::int as n from pg_checkout_sessions')).rows[0].n, 0);
  } finally {
    await db.close();
  }
});

test('약관 동의 확인이 먼저다. 앱 패키지로 지정한 상품이 없으면 아무것도 막지 않는다', async () => {
  const db = await setup();
  try {
    await assert.rejects(
      db.query("select create_guest_order(array[21]::bigint[], array[1], '홍', '010', '1', '주소', null, null, null, null, null, false)"),
      /약관 및 개인정보 수집 동의/,
    );
    await db.exec('delete from ilseong_app_products');
    assert.equal((await guestOrder(db, [21])).rows[0].r.core_called, true);
  } finally {
    await db.close();
  }
});

test('검사 함수는 밖에서 직접 부를 수 없다', async () => {
  const db = await setup();
  try {
    const rows = (await db.query(`
      select has_function_privilege('anon', '_ilseong_app_assert_member_purchase(bigint[])', 'execute') as anon,
             has_function_privilege('authenticated', '_ilseong_app_assert_member_purchase(bigint[])', 'execute') as authed
    `)).rows[0];
    assert.deepEqual(rows, { anon: false, authed: false });
  } finally {
    await db.close();
  }
});
