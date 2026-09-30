import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = (name) => readFileSync(new URL(`../supabase/migrations/${name}.sql`, import.meta.url), 'utf8');
const baseline = migration('20260702150000_direct_preparing_on_payment');
const patch = migration('20260930022817_fix_payment_confirmation_refunded_items');

test('부분환불 재판매의 결제 확정과 기존 결제 보호 조건', async (t) => {
  const db = new PGlite();
  const confirm = async (path, amount = 23400, key = 'test-payment') => {
    const sql = path === 'bank'
      ? 'select public.admin_confirm_payment(365, $1::integer) as result'
      : "select public.confirm_pg_payment('ORD-TEST-0396', $2, $1::integer, 'nicepay', '{\"test\":true}'::jsonb) as result";
    return (await db.query(sql, path === 'bank' ? [amount] : [amount, key])).rows[0].result;
  };
  const seed = async () => db.exec(`
    reset role;
    select set_config('test.admin', 'true', false);
    truncate public.orders, public.order_items, public.books;
    insert into public.orders (id, order_number, status, payment_status, payment_method, total_amount)
      values (193,'ORD-TEST-0219','confirmed','paid','card',29275),
             (365,'ORD-TEST-0396','pending','pending','bank_transfer',23400);
    insert into public.books values (6282,'reserved'),(6289,'on_sale'),(6655,'reserved');
    insert into public.order_items values
      (193,6282,'2026-09-04T01:30:10Z'),(193,6655,null),(365,6282,null),(365,6289,null);
  `);
  const state = async () => (await db.query('select status, payment_status, payment_key from public.orders where id=365')).rows[0];
  const definitions = async () => (await db.query(`
    select proname, pg_get_functiondef(oid) as definition, proacl::text as acl, prosecdef, proconfig
    from pg_proc where pronamespace='public'::regnamespace
      and proname in ('admin_confirm_payment','confirm_pg_payment') order by proname
  `)).rows;
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create function public.is_admin_user() returns boolean language sql stable
        as $$ select coalesce(current_setting('test.admin',true),'false')::boolean $$;
      create table public.orders (
        id bigint primary key, order_number text unique, status text, payment_status text,
        payment_method text, total_amount integer, updated_at timestamptz,
        payment_key text, pg_provider text, pg_approved_at timestamptz, pg_raw jsonb
      );
      create table public.books (id bigint primary key, status text);
      create table public.order_items (order_id bigint, book_id bigint, refunded_at timestamptz);
      alter table public.orders enable row level security;
      alter table public.books enable row level security;
      alter table public.order_items enable row level security;
    `);
    await db.exec(baseline);
    await db.exec(migration('20260707100000_admin_bulk_confirm_payment'));
    await seed();
    await t.test('기존 함수에서 환불된 책의 오류를 두 경로 모두 재현', async () => {
      for (const path of ['bank', 'pg']) await assert.rejects(confirm(path), /충돌 주문: \{193\}/);
    });
    const before = await definitions();
    await db.exec(patch);
    await t.test('함수 본문은 환불 조건 하나씩만 변경하고 권한은 보존', async () => {
      const after = await definitions();
      assert.deepEqual(after.map((fn) => ({ ...fn, definition: fn.definition.replace('    and oi2.refunded_at is null\n', '') })), before);
    });
    for (const path of ['bank', 'pg']) {
      await t.test(`${path}: 과거 환불 책의 새 결제 확정과 재고 예약`, async () => {
        await seed();
        const result = await confirm(path);
        assert.equal(result.success, true);
        assert.equal(result.new_status, 'preparing');
        assert.equal(result.verified_amount, 23400);
        assert.equal((await state()).payment_status, 'paid');
        assert.deepEqual((await db.query('select status from public.books order by id')).rows.map((b) => b.status), ['reserved', 'reserved', 'reserved']);
        assert.deepEqual((await db.query('select status, payment_status from public.orders where id=193')).rows[0], { status: 'confirmed', payment_status: 'paid' });
        assert.equal((await db.query('select count(*)::int as n from public.order_items where refunded_at is not null')).rows[0].n, 1);
        if (path === 'pg') {
          const pg = (await db.query('select pg_provider, pg_approved_at, pg_raw from public.orders where id=365')).rows[0];
          assert.equal(pg.pg_provider, 'nicepay');
          assert.ok(pg.pg_approved_at);
          assert.deepEqual(pg.pg_raw, { test: true });
          assert.equal((await confirm(path)).idempotent, true);
          await assert.rejects(confirm(path, 23400, 'different-key'), /Cannot confirm payment/);
        }
      });
      await t.test(`${path}: 미환불 품목의 실제 중복 판매는 모든 확정 상태에서 거부`, async () => {
        for (const status of ['paid', 'preparing', 'shipping', 'delivered', 'confirmed']) {
          await seed();
          await db.exec('update public.order_items set refunded_at=null where order_id=193 and book_id=6282');
          await db.query('update public.orders set status=$1 where id=193', [status]);
          await assert.rejects(confirm(path), /충돌 주문: \{193\}/);
          assert.equal((await state()).status, 'pending');
        }
      });
      await t.test(`${path}: 환불 이력이 있어도 별도 미환불 주문이 있으면 거부`, async () => {
        await seed();
        await db.exec("insert into public.orders(id,status) values(400,'preparing'); insert into public.order_items values(400,6282,null)");
        await assert.rejects(confirm(path), /충돌 주문: \{400\}/);
      });
      await t.test(`${path}: 취소·전액환불 주문 제외와 금액·주문 상태 검증 유지`, async () => {
        for (const status of ['cancelled', 'refunded']) {
          await seed();
          await db.exec('update public.order_items set refunded_at=null where order_id=193');
          await db.query('update public.orders set status=$1 where id=193', [status]);
          assert.equal((await confirm(path)).success, true);
        }
        await seed();
        await assert.rejects(confirm(path, 1), /일치하지 않습니다/);
        assert.equal((await state()).status, 'pending');
        await db.exec("update public.orders set status='cancelled' where id=365");
        await assert.rejects(confirm(path), /Cannot confirm payment/);
      });
    }
    await t.test('일괄 입금확인도 같은 수정 적용', async () => {
      await seed();
      const result = (await db.query('select public.admin_bulk_confirm_payment(array[365::bigint]) as result')).rows[0].result;
      assert.deepEqual(result.success_ids, [365]);
      assert.equal(result.fail_count, 0);
    });
    await t.test('일반 회원 관리자 검사와 PG service_role 전용 권한 유지', async () => {
      await seed();
      await db.exec("select set_config('test.admin','false',false); set role authenticated");
      await assert.rejects(confirm('bank'), /Admin access required/);
      await assert.rejects(confirm('pg'), /permission denied/);
      await db.exec('set role anon');
      await assert.rejects(confirm('pg'), /permission denied/);
      await db.exec('set role service_role');
      assert.equal((await confirm('pg')).success, true);
      await db.exec('reset role');
    });
    await t.test('예상과 다른 함수 정의에서는 전체 migration 원자적 중단', async () => {
      await db.exec(before.find((fn) => fn.proname === 'admin_confirm_payment').definition);
      await assert.rejects(db.exec(patch), /Expected exactly one unpatched/);
      const after = await definitions();
      assert.equal(after.find((fn) => fn.proname === 'admin_confirm_payment').definition, before.find((fn) => fn.proname === 'admin_confirm_payment').definition);
    });
  } finally {
    await db.close();
  }
});

test('부분환불된 책의 취소 주문 복원부터 입금확인까지', async (t) => {
  const db = new PGlite();
  const restorePatch = migration('20260930023435_fix_order_restore_refunded_items');
  const restoreSql = migration('20260830193508_admin_restore_cancelled_order')
    .match(/create or replace function public\.admin_restore_cancelled_order\([\s\S]*?\$\$;/i)?.[0];
  assert.ok(restoreSql);
  const restore = async (validateOnly = false) => (await db.query(
    'select public.admin_restore_cancelled_order(365,$1) as result', [validateOnly],
  )).rows[0].result;
  const seed = async () => db.exec(`
    reset role; select set_config('test.admin','true',false);
    truncate public.orders, public.books, public.order_items, public.member_coupons;
    insert into public.orders(id,order_number,status,payment_status,payment_method,total_amount,item_count,refunded_amount)
      values(193,'ORD-TEST-0219','confirmed','paid','card',29275,2,8400),
            (365,'ORD-TEST-0396','cancelled','pending','bank_transfer',23400,2,0);
    insert into public.books values(6282,'on_sale',2424),(6289,'on_sale',2431);
    insert into public.order_items values(697,193,6282,'상크스','2026-09-04T01:30:10Z'),
      (1340,365,6282,'상크스',null),(1341,365,6289,'개념형 모의고사',null);
  `);
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.uid() returns uuid language sql as $$ select null::uuid $$;
      create function public.is_admin_user() returns boolean language sql stable
        as $$ select coalesce(current_setting('test.admin',true),'false')::boolean $$;
      create table public.orders(id bigint primary key,order_number text,status text,payment_status text,
        payment_method text,total_amount integer,item_count integer,paid_at timestamptz,payment_key text,
        refunded_at timestamptz,refunded_amount integer,applied_member_coupon_id bigint,
        restored_at timestamptz,restored_by uuid,payment_reminder_sent_at timestamptz,updated_at timestamptz,
        pg_provider text,pg_approved_at timestamptz,pg_raw jsonb);
      create table public.books(id bigint primary key,status text,serial_number integer);
      create table public.order_items(id bigint primary key,order_id bigint,book_id bigint,title text,refunded_at timestamptz);
      create table public.member_coupons(id bigint primary key,status text,used_at timestamptz,used_order_id bigint,updated_at timestamptz);
    `);
    await db.exec(restoreSql);
    await db.exec(baseline);
    await db.exec(patch);
    await seed();
    await t.test('기존 복원 차단을 재현하고 조건 하나만 변경', async () => {
      assert.equal((await restore(true)).success, false);
      const before = (await db.query("select pg_get_functiondef('public.admin_restore_cancelled_order(bigint,boolean)'::regprocedure) as definition")).rows[0].definition;
      await db.exec(restorePatch);
      const after = (await db.query("select pg_get_functiondef('public.admin_restore_cancelled_order(bigint,boolean)'::regprocedure) as definition")).rows[0].definition;
      assert.equal(after.replace('                and oi2.refunded_at is null\n',''), before);
    });
    await t.test('검증 전용은 그대로 두고 복원은 입금대기·재선점·만료 시계 갱신', async () => {
      assert.equal((await restore(true)).success, true);
      assert.equal((await db.query('select status from public.orders where id=365')).rows[0].status, 'cancelled');
      const result = await restore();
      assert.equal(result.success, true);
      assert.equal(result.new_status, 'pending');
      assert.equal(result.books_reserved, 2);
      const order = (await db.query('select status,payment_status,total_amount,restored_at from public.orders where id=365')).rows[0];
      assert.equal(order.status, 'pending');
      assert.equal(order.payment_status, 'pending');
      assert.equal(order.total_amount, 23400);
      assert.ok(order.restored_at);
      const confirmed = (await db.query('select public.admin_confirm_payment(365,23400) as result')).rows[0].result;
      assert.equal(confirmed.new_status, 'preparing');
    });
    await t.test('타 주문의 미환불 예약과 판매·폐기 재고는 계속 차단', async () => {
      for (const status of ['pending','preparing','confirmed']) {
        await seed();
        await db.query('insert into public.orders(id,status) values(400,$1)', [status]);
        await db.exec("insert into public.order_items values(1500,400,6282,'상크스',null)");
        assert.equal((await restore()).success, false);
      }
      for (const status of ['settled','discarded']) {
        await seed();
        await db.query('update public.books set status=$1 where id=6282', [status]);
        assert.equal((await restore()).success, false);
      }
    });
    await t.test('결제·환불 이력과 관리자 검사 유지', async () => {
      for (const assignment of ["paid_at=now()", "payment_key='paid-key'", "refunded_at=now()", 'refunded_amount=1']) {
        await seed();
        await db.exec(`update public.orders set ${assignment} where id=365`);
        await assert.rejects(restore(), /결제·환불 이력/);
      }
      await seed();
      await db.exec("select set_config('test.admin','false',false)");
      await assert.rejects(restore(), /Admin access required/);
    });
    await t.test('기존 쿠폰 재소진과 다른 주문에 사용한 쿠폰 차단 유지', async () => {
      await seed();
      await db.exec("insert into public.member_coupons(id,status) values(1,'available'); update public.orders set applied_member_coupon_id=1 where id=365");
      assert.equal((await restore()).coupons_reconsumed, 1);
      assert.equal((await db.query('select used_order_id from public.member_coupons where id=1')).rows[0].used_order_id, 365);
      await seed();
      await db.exec("insert into public.member_coupons(id,status,used_order_id) values(1,'used',400); update public.orders set applied_member_coupon_id=1 where id=365");
      assert.equal((await restore()).success, false);
    });
  } finally {
    await db.close();
  }
});
