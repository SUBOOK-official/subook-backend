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
