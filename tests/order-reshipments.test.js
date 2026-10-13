import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
const admin = '00000000-0000-0000-0000-000000000001';
const q = async (sql, params = []) => (await db.query(sql, params)).rows;
let next = 1;
async function fixture(status = 'delivered') {
  const id = next++;
  await q("insert into orders(id,status,payment_status,tracking_number,total_amount,refund_requested_at) values($1,$2,'paid','ORIGINAL',12000,now())", [id,status]);
  await q('insert into order_items(id,order_id,quantity) values($1,$1,2)', [id]);
  return { id, key: randomUUID(), items: [{ orderItemId:id,title:'아폴로N 고체편',quantity:1 }] };
}
async function claim(order, { key=order.key, items=order.items, latest=null } = {}) {
  return (await q('select admin_claim_order_reshipment($1,$2,$3,$4,$5,$6) result',
    [order.id,key,admin,'오배송으로 고체편 무상 재발송',JSON.stringify(items),latest]))[0].result;
}
async function transition(row, action, tracking=null, token=row.claim_token) {
  return (await q('select admin_transition_order_reshipment($1,$2,$3,$4,$5) result',
    [row.id,token,action,tracking,JSON.stringify({clsfCd:'2T01'})]))[0].result;
}
before(async () => {
  await db.exec(`create role anon; create role authenticated; create role service_role;
    create schema auth; create table auth.users(id uuid primary key); insert into auth.users values('${admin}');
    create table orders(id bigint primary key,status text,payment_status text,tracking_number text,total_amount int,
      shipping_recipient_name text,shipping_recipient_phone text,shipping_postal_code text,shipping_address_line1 text,
      shipping_address_line2 text,shipping_memo text,refund_requested_at timestamptz,refund_request_resolved_at timestamptz);
    create table order_items(id bigint primary key,order_id bigint references orders(id),quantity int,refunded_at timestamptz);
    grant usage on schema public to anon,authenticated,service_role;`);
  await db.exec(await readFile(new URL('../supabase/migrations/20261013080450_order_reshipments.sql',import.meta.url),'utf8'));
});
after(() => db.close());

test('환불 신청 중 주문도 무상 재발송하며 원 주문·품목·금액·송장·환불 보류를 보존', async () => {
  const order = await fixture();
  const before = await q('select * from orders where id=$1',[order.id]);
  let row = await claim(order);
  assert.equal(row.reason,'오배송으로 고체편 무상 재발송');
  assert.deepEqual(row.items,order.items);
  row = await transition(row,'booking','123456789012');
  row = await transition(row,'registered');
  assert.equal(row.state,'registered');
  assert.deepEqual(await q('select * from orders where id=$1',[order.id]),before);
  assert.equal((await q('select quantity from order_items where id=$1',[order.id]))[0].quantity,2);
  assert.equal((await claim(order)).id,row.id);
  await assert.rejects(claim(order,{items:[{...order.items[0],title:'수정된 교재'}]}),/이미 접수/);
});
test('동시·중복 발급, 오래된 화면의 추가 접수를 차단하고 명시적으로 확인한 추가 재발송만 허용',async()=>{
  const order=await fixture(); let row=await claim(order);
  await assert.rejects(claim(order),/처리 중/);
  await assert.rejects(claim(order,{key:randomUUID(),latest:row.id}),/진행 중인 재발송/);
  row=await transition(row,'booking','123456789012');
  await assert.rejects(claim(order),/CJ 접수 결과/);
  await assert.rejects(transition(row,'failed'),/자동 재발급/);
  row=await transition(row,'registered');
  await assert.rejects(claim(order,{key:randomUUID()}),/이력이 변경/);
  const second=await claim(order,{key:randomUUID(),latest:row.id});
  assert.notEqual(row.id,second.id);
});
test('명시적 거부와 채번 전 실패만 재시도하고 소유권 토큰을 교체',async()=>{
  const order=await fixture(); let row=await claim(order); const token=row.claim_token;
  await transition(row,'failed'); row=await claim(order);
  assert.notEqual(row.claim_token,token);
  await assert.rejects(transition(row,'booking','123456789012',token),/소유권/);
  await assert.rejects(transition(row,'booking','invalid'),/자동 재발급/);
  row=await transition(row,'booking','123456789012');
  row=await transition(row,'rejected');
  assert.equal(row.state,'failed');
  assert.equal((await claim(order)).id,row.id);
});
test('만료된 claimed 건은 같은 요청으로 복구하며 이전 실패건은 새 발급 이후 재개 불가',async()=>{
  const order=await fixture(); let row=await claim(order);
  await q("update order_reshipments set updated_at=now()-interval '11 minutes' where id=$1",[row.id]);
  row=await claim(order);
  await transition(row,'failed');
  await claim(order,{key:randomUUID(),latest:row.id});
  await assert.rejects(claim(order),/이력이 변경/);
});
test('잘못된 품목·기환불·수량 초과·중복·미결제·미발송은 CJ 발급 전 차단',async()=>{
  const order=await fixture(); const other=await fixture();
  for(const items of [[],null,[{...order.items[0],quantity:0}],[{...order.items[0],quantity:3}],
    [{...order.items[0],title:''}],other.items,[...order.items,...order.items]]) {
    await assert.rejects(claim(order,{items}),/교재|품목/);
  }
  await q('update order_items set refunded_at=now() where id=$1',[order.id]);
  await assert.rejects(claim(order),/미환불/);
  for(const status of ['pending','preparing','cancelled','refunded']) await assert.rejects(claim(await fixture(status)),/발송된 주문/);
  const unpaid=await fixture(); await q("update orders set payment_status='pending' where id=$1",[unpaid.id]);
  await assert.rejects(claim(unpaid),/발송된 주문/);
});
test('CJ 접수 동안 주소·환불 품목 변경은 차단되고 확정 후 기존 처리 가능',async()=>{
  const order=await fixture(); let row=await claim(order);
  await assert.rejects(q("update orders set shipping_address_line1='변경' where id=$1",[order.id]),/송장 처리 중/);
  row=await transition(row,'booking','123456789012');
  await assert.rejects(q('update order_items set refunded_at=now() where id=$1',[order.id]),/송장 처리 중/);
  await transition(row,'registered');
  await q('update order_items set refunded_at=now() where id=$1',[order.id]);
});
test('RLS와 RPC 권한: 일반 회원·비회원 조회/수정/발급 차단, service_role 전용',async()=>{
  assert.equal((await q("select relrowsecurity from pg_class where relname='order_reshipments'"))[0].relrowsecurity,true);
  for(const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    try {
      await assert.rejects(q('select * from order_reshipments'),/permission denied/);
      await assert.rejects(q("update order_reshipments set state='registered'"),/permission denied/);
      await assert.rejects(q('select admin_claim_order_reshipment(1,null,null,null,null,null)'),/permission denied/);
      await assert.rejects(q("select admin_transition_order_reshipment(1,null,'registered')"),/permission denied/);
    } finally { await db.exec('reset role'); }
  }
  const order=await fixture(); await db.exec('set role service_role');
  try { assert.equal((await claim(order)).state,'claimed'); } finally { await db.exec('reset role'); }
});
