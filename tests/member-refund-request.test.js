import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const buyer = "00000000-0000-0000-0000-000000000001";
const other = "00000000-0000-0000-0000-000000000002";
let next = 1;
const query = async (sql, params = []) => (await db.query(sql, params)).rows;
const login = async (id = buyer, admin = false) => {
  await query("select set_config('app.uid',$1,false), set_config('app.admin',$2,false)", [id, String(admin)]);
};
async function fixture({ user = buyer, status = "delivered", age = "0 days" } = {}) {
  const id = next++;
  await query("insert into orders(id,user_id,status,updated_at) values($1,$2,$3,now()-$4::interval)", [id,user,status,age]);
  const ids = [id * 10, id * 10 + 1];
  await query("insert into order_items(id,order_id) values($1,$3),($2,$3)", [...ids,id]);
  return { id, ids };
}
async function request(order, ids = order.ids) {
  return (await query("select request_member_refund($1,'[상품 하자] 답안이 모두 적혀 있는 교재가 도착했습니다.',$2::bigint[]) result", [order.id, ids]))[0].result;
}
before(async () => {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid',true),'')::uuid $$;
    create function is_admin_user() returns boolean language sql as $$ select current_setting('app.admin',true)='true' $$;
    create table orders(id bigint primary key,user_id uuid,status text,created_at timestamptz default now(),updated_at timestamptz,
      refund_requested_at timestamptz,refund_request_reason text,refund_request_resolved_at timestamptz);
    create table order_items(id bigint primary key,order_id bigint references orders(id),refunded_at timestamptz);
    alter table orders enable row level security;
    grant usage on schema public,auth to authenticated;
    grant select on orders to authenticated;
    create policy own_orders on orders for select to authenticated using(user_id=auth.uid() or is_admin_user());
  `);
  await db.exec(await readFile(new URL("../supabase/migrations/20261005145939_member_refund_request_items.sql",import.meta.url),"utf8"));
  await login();
});
after(() => db.close());

test("선택 품목만 원자적으로 저장하고 요청 시각·사유·기존 보류 상태를 유지", async () => {
  const order = await fixture();
  const result = await request(order,[order.ids[1],order.ids[1]]);
  assert.deepEqual(result.item_ids,[order.ids[1]]);
  assert.deepEqual((await query("select order_item_id from order_refund_request_items where order_id=$1",[order.id])).map(row=>row.order_item_id),[order.ids[1]]);
  const stored = (await query("select * from orders where id=$1",[order.id]))[0];
  assert.ok(stored.refund_requested_at);
  assert.equal(stored.refund_request_resolved_at,null);
  assert.match(stored.refund_request_reason,/답안/);
  assert.equal(stored.status,"delivered");
  await assert.rejects(request(order),/이미 환불 신청/);
});
test("미선택·NULL·잘못된 품목·다른 주문 품목·기환불 품목은 부분 저장 없이 차단", async () => {
  const order = await fixture(); const another = await fixture();
  await query("update order_items set refunded_at=now() where id=$1",[order.ids[1]]);
  for (const ids of [[],null,[null],[order.ids[0],another.ids[0]],[order.ids[0],999999],order.ids]) {
    await assert.rejects(request(order,ids),/교재/);
    assert.equal((await query("select count(*)::int n from order_refund_request_items where order_id=$1",[order.id]))[0].n,0);
    assert.equal((await query("select refund_requested_at from orders where id=$1",[order.id]))[0].refund_requested_at,null);
  }
});
test("로그인·소유권·기존 배송상태와 7일 신청 조건 유지", async () => {
  const order = await fixture();
  await login(""); await assert.rejects(request(order),/Authentication/);
  await login(other); await assert.rejects(request(order),/주문을 찾을/);
  await login();
  for (const [options,error] of [[{status:"confirmed"},/구매확정된 주문/],[{status:"shipping"},/배송완료/],[{age:"8 days"},/7일/]]) {
    await assert.rejects(request(await fixture(options)),error);
  }
});
test("2인자 구버전 신청은 새로고침 안내로 차단하고 기존 신청은 미기록 유지",async()=>{
  const order=await fixture();
  await assert.rejects(query("select request_member_refund($1,'기존 요청 사유')",[order.id]),/새로고침/);
  await query("update orders set refund_requested_at=now(),refund_request_reason='이전 신청' where id=$1",[order.id]);
  assert.equal((await query("select count(*)::int n from order_refund_request_items where order_id=$1",[order.id]))[0].n,0);
});
test("RLS: 본인과 관리자만 읽고 구매자 직접 쓰기·수정·삭제는 금지",async()=>{
  const mine=await fixture(); const theirs=await fixture({user:other});
  await request(mine); await login(other); await request(theirs); await login();
  await db.exec("set role authenticated");
  try {
    const visible=await query("select distinct order_id from order_refund_request_items");
    assert.ok(visible.some(row=>row.order_id===mine.id));
    assert.ok(!visible.some(row=>row.order_id===theirs.id));
    // 실제 authenticated 권한으로도 SECURITY DEFINER 접수만 허용된다.
    await assert.rejects(query("insert into order_refund_request_items values(999,999,now())"),/permission denied/);
    await assert.rejects(query("update order_refund_request_items set order_id=999"),/permission denied/);
    await assert.rejects(query("delete from order_refund_request_items"),/permission denied/);
    await login(buyer,true);
    assert.ok((await query("select distinct order_id from order_refund_request_items")).some(row=>row.order_id===theirs.id));
  } finally { await db.exec("reset role"); await login(); }
  const viaRpc=await fixture();
  await db.exec("set role authenticated");
  try { assert.equal((await request(viaRpc)).success,true); }
  finally { await db.exec("reset role"); }
  await db.exec("set role anon");
  try { await assert.rejects(query("select * from order_refund_request_items"),/permission denied/); }
  finally { await db.exec("reset role"); }
});
