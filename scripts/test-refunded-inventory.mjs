// 운영 연결 없이 실제 create_order_core를 PostgreSQL에서 실행해 예약 검사를 검증한다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const read = (file) => readFileSync(new URL(file, import.meta.url), 'utf8');
const original = process.argv[2] ? readFileSync(process.argv[2], 'utf8') : read('../supabase/migrations/20260902111905_member_points.sql')
  .match(/CREATE OR REPLACE FUNCTION public\.create_order_core\([\s\S]*?\$function\$;/i)?.[0];
assert.ok(original, 'baseline core found');
const patch = read('../supabase/migrations/20260929033735_fix_refunded_inventory_reservation.sql');
const db = new PGlite();
try {
  await db.exec(`
    create table member_profiles(user_id uuid, is_blocked boolean, phone text);
    create table books(id bigint primary key,status text,is_public boolean,price int);
    create table orders(id bigint,status text);
    create table order_items(book_id bigint,order_id bigint,refunded_at timestamptz);
    create table member_coupons(id bigint,user_id uuid,status text,expires_at timestamptz,coupon_id bigint,used_at timestamptz,used_order_id bigint);
    create table coupons(id bigint,is_active boolean,min_order_amount int,usage_limit_per_user int,discount_type text,discount_value int,max_discount_amount int);
    create function point_policy() returns jsonb language sql as 'select ''{}''::jsonb';
    create function get_remote_area_surcharge(text) returns int language sql as 'select 0';
    insert into books values(1,'on_sale',true,12000),(2,'on_sale',true,14000),(3,'reserved',false,14000);
    insert into orders values(1,'confirmed'),(2,'pending'),(3,'cancelled'),(4,'refunded');
    insert into order_items values(1,1,now()),(2,2,null);
  `);
  await db.exec(original);
  const call = (book, guest = true) => db.query(`select public.create_order_core(
    p_user_id=>$1::uuid,p_book_ids=>array[$2::bigint],p_quantities=>array[1],
    p_shipping_recipient_name=>'테스트',p_shipping_recipient_phone=>'01000000000',
    p_shipping_postal_code=>'06000',p_shipping_address_line1=>'테스트',p_shipping_address_line2=>'',
    p_shipping_memo=>'',p_payment_method=>'card',p_validate_only=>true,p_is_guest=>$3) as result`,
  [guest ? null : '00000000-0000-4000-8000-000000000001', book, guest]);
  await assert.rejects(call(1), /already reserved/);
  const before = (await db.query("select pg_get_functiondef(oid) as definition from pg_proc where proname='create_order_core'")).rows[0].definition;
  await db.exec(patch);
  const after = (await db.query("select pg_get_functiondef(oid) as definition from pg_proc where proname='create_order_core'")).rows[0].definition;
  assert.equal(after.replace('      and oi.refunded_at is null\n', ''), before, 'only reservation predicate changes');
  for (const guest of [true, false]) {
    assert.equal((await call(1, guest)).rows[0].result.total_amount, 15000);
    await assert.rejects(call(2, guest), /already reserved/);
    await assert.rejects(call(3, guest), /not available/);
  }
  await db.exec('insert into order_items values(1,2,null)');
  await assert.rejects(call(1), /already reserved/, 'new active reservation still blocks resale');
  await db.exec('delete from order_items where book_id=1 and order_id=2; insert into order_items values(1,3,null),(1,4,null)');
  assert.equal((await call(1)).rows[0].result.total_amount, 15000);
  assert.equal((await db.query('select count(*)::int as n from orders')).rows[0].n, 4, 'validation creates no orders');
  await assert.rejects(db.exec(patch), /Expected exactly one/);
  console.log('PASS: refunded resale, member/guest validation, active/hidden stock rejection, cancelled/refunded history, unchanged function, drift guard');
} finally { await db.close(); }
