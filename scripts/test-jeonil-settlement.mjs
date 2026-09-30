// 실제 migration을 격리 PostgreSQL에서 실행한다. 운영 데이터·알림·송금에 접근하지 않는다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
const get = async () => (await db.query('select public.admin_get_jeonil_settlements() as result')).rows[0].result;
const pay = (ids, amount) => db.query("select public.admin_complete_jeonil_settlements($1::bigint[], $2::bigint, '테스트 이체') as result", [ids, amount]);
try {
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
    create function public.is_admin_user() returns boolean language sql as $$ select current_setting('test.admin', true) = 'true' $$;
    create table public.orders (id bigint primary key, order_number text, status text, payment_status text, confirmed_at timestamptz, refund_requested_at timestamptz, refund_request_resolved_at timestamptz);
    create table public.books (id bigint primary key, title text, brand text, shipment_id bigint);
    create table public.order_items (id bigint primary key, order_id bigint, book_id bigint, product_id bigint, title text, option_label text, quantity integer, total_price integer, unit_price integer, refunded_at timestamptz);
    create table public.settlements (order_id bigint, book_id bigint, status text);
    create table public.manual_settlements (book_id bigint, status text);
    create table public.order_return_cases (order_id bigint, status text);
    select set_config('test.admin','true',false), set_config('test.uid','11111111-1111-4111-8111-111111111111',false);
  `);
  await db.exec(readFileSync(new URL('../supabase/migrations/20260930080508_jeonil_separate_settlement.sql', import.meta.url), 'utf8'));
  await db.exec(`
    insert into orders(id,order_number,status,payment_status,confirmed_at)
      select id, 'ORDER-'||id, 'confirmed','paid',now() from generate_series(1,14) id;
    insert into books(id,title,brand) select id,'전일 교재 '||id,'전일학원' from generate_series(1,14) id;
    insert into order_items(id,order_id,book_id,product_id,title,option_label,quantity,total_price,unit_price)
      select id,id,id,2370,'구매 당시 교재명','FULL',1,59000,59000 from generate_series(1,14) id;
    update order_items set quantity=2,total_price=138000,unit_price=69000 where id=2;
    update orders set status='delivered' where id=3;
    update orders set status='refunded',payment_status='refunded' where id=4;
    update orders set status='cancelled' where id=5;
    update orders set status='pending',payment_status='pending' where id=6;
    update books set brand='다른출판사' where id=7;
    update books set shipment_id=888 where id=8;
    update orders set refund_requested_at=now() where id=9;
    insert into order_return_cases values(10,'processing');
    insert into manual_settlements values(11,'paid');
    insert into settlements values(12,12,'pending');
    update order_items set refunded_at=now() where id=13;
    update orders set refund_requested_at=now(),refund_request_resolved_at=now() where id=14;
    update order_items set total_price=10001,unit_price=10001 where id=14;
  `);
  let result = await get();
  assert.deepEqual(result.payable.map(r => r.order_item_id), [1,2,14]);
  assert.deepEqual(result.waiting.map(r => r.order_item_id), [3,9,10]);
  assert.equal(result.payable.find(r => r.order_item_id === 2).net_amount, 69000);
  assert.equal(result.payable.find(r => r.order_item_id === 14).net_amount, 5000);
  assert.equal(result.payable.find(r => r.order_item_id === 14).fee_amount, 5001);
  assert.ok(result.payable.every(r => r.book_title === '구매 당시 교재명'));
  console.log('PASS: 구매확정·50%·주문 당시 가격·수량·원단위 반올림·취소/환불/일반셀러/기존원장 제외');

  for (const [ids, amount] of [[[1],1], [[3],29500], [[9],29500], [[10],29500], [[7],29500], [[1,1],59000], [[1,null],29500], [[],0], [[999],0]]) {
    await assert.rejects(pay(ids, amount));
  }
  assert.equal((await db.query('select count(*)::int as count from jeonil_settlement_payments')).rows[0].count, 0);
  await assert.rejects(db.query("select admin_complete_jeonil_settlements(array[1]::bigint[],29500,'')"));
  console.log('PASS: 미확정·환불진행·금액변경·위조ID·중복ID·빈 메모는 전체 거부');

  await pay([1,2],98500);
  result = await get();
  assert.deepEqual(result.payable.map(r=>r.order_item_id), [14]);
  assert.equal(result.completed.length,2);
  assert.equal(result.completed.reduce((sum,r)=>sum+r.net_amount,0),98500);
  await assert.rejects(pay([1,2],98500));
  assert.equal((await get()).completed.length,2);
  await db.exec("update orders set status='confirmed',confirmed_at=now() where id=3;");
  assert.ok((await get()).payable.some(r=>r.order_item_id===3));
  await db.exec("update order_items set refunded_at=now() where id=3;");
  await assert.rejects(pay([3],29500));
  await db.exec("update order_items set refunded_at=now() where id=1;");
  result = await get();
  assert.equal(result.completed.find(r=>r.order_item_id===1).refunded_after_payment,true);
  assert.equal(result.completed.find(r=>r.order_item_id===1).net_amount,29500);
  assert.ok(!result.payable.some(r=>r.order_item_id===1));
  console.log('PASS: 지급 기록·재요청 중복 방지·새 구매확정 반영·지급 직전 환불 차단·지급 후 환불 이력 보존');

  await db.exec("select set_config('test.admin','false',false); set role authenticated;");
  await assert.rejects(get(), /Admin access required/);
  await assert.rejects(pay([14],5000), /Admin access required/);
  assert.equal((await db.query('select * from jeonil_settlement_payments')).rows.length,0);
  await assert.rejects(db.query('select * from jeonil_settlement_candidates()'), /permission denied/);
  await assert.rejects(db.query('delete from jeonil_settlement_payments'), /permission denied/);
  await db.exec('reset role; set role anon;');
  await assert.rejects(get(), /permission denied/);
  await assert.rejects(pay([14],5000), /permission denied/);
  await assert.rejects(db.query('select * from jeonil_settlement_payments'), /permission denied/);
  await db.exec("reset role; select set_config('test.admin','true',false),set_config('test.uid','',false);");
  await assert.rejects(pay([14],5000), /Admin access required/);
  console.log('PASS: 비관리자·익명 RPC 차단·RLS 조회 차단·직접 원장 수정 차단·내부 함수 비공개·행위자 필수');
} finally { await db.close(); }
