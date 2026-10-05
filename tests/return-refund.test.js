import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const adminId = "00000000-0000-0000-0000-000000000001";
const buyerId = "00000000-0000-0000-0000-000000000002";
let nextId = 100;
async function query(sql, params = []) { return (await db.query(sql, params)).rows; }
async function rpc(name, args = []) {
  return (await query(`select public.${name}(${args.map((_, i) => `$${i + 1}`).join(",")}) as result`, args))[0].result;
}
async function fixture({ total = 23000, shipping = 3000, method = "card", status = "delivered", prices = [10000, 10000], settled = false, coupon = false, settlements = true } = {}) {
  const id = nextId++;
  await query(`insert into orders(id,order_number,user_id,status,total_amount,shipping_fee,subtotal,payment_method,payment_key,pg_provider,applied_member_coupon_id)
    values($1,$2,$3,$4,$5,$6,$7,$8,$9,'nicepay',$10)`, [id,`TEST-${id}`,buyerId,status,total,shipping,prices.reduce((a,b)=>a+b,0),method,method === "card" ? `tid-${id}` : null,coupon ? id : null]);
  if (coupon) await query("insert into member_coupons(id,status,used_order_id,used_at) values($1,'used',$1,now())",[id]);
  const ids = [];
  for (const price of prices) {
    const itemId = nextId++;
    ids.push(itemId);
    await query("insert into books(id,status,is_public) values($1,'reserved',false)",[itemId]);
    await query("insert into order_items(id,order_id,book_id,title,total_price) values($1,$2,$1,'시험용 교재',$3)",[itemId,id,price]);
    if (settlements) await query("insert into settlements(order_id,book_id,status) values($1,$2,$3)",[id,itemId,settled ? "completed" : "pending"]);
  }
  return { id, ids };
}
const start = (order, reason="buyer_remorse", ids=order.ids) => rpc("admin_start_order_return",[order.id,ids,reason,"시험용 반품 사유"]);
const receive = (id, ids) => rpc("admin_receive_order_return",[id,ids]);
const approve = (id, opts={}) => rpc("admin_review_order_return",[id,true,"교재와 구성품 및 상태 확인 완료",opts.restock ?? true,opts.amount ?? null,opts.fee ?? null,opts.note ?? null]);
const claim = (id, reference=null, ack=false) => rpc("admin_claim_return_refund",[id,reference,ack]);

before(async () => {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql as $$select nullif(current_setting('app.uid',true),'')::uuid$$;
    create function public.is_admin_user() returns boolean language sql as $$select current_setting('app.is_admin',true)='true'$$;
    create table orders(id bigint primary key,order_number text,user_id uuid,status text,total_amount integer,shipping_fee integer,subtotal integer,
      payment_method text,payment_key text,pg_provider text,payment_status text default 'paid',refunded_amount integer default 0,
      applied_member_coupon_id bigint,refund_requested_at timestamptz,refund_request_reason text,refund_request_resolved_at timestamptz,
      refunded_at timestamptz,refund_reason text,created_at timestamptz default now(),updated_at timestamptz,auto_confirm_at timestamptz,confirmed_at timestamptz,tracking_number text,points_used integer default 0);
    create table books(id bigint primary key,status text,is_public boolean,shipment_id bigint,condition_grade text);
    create table order_items(id bigint primary key,order_id bigint references orders(id),book_id bigint references books(id),title text,total_price integer,
      refunded_at timestamptz,refund_amount integer,refund_reason text,restock_held_at timestamptz,quantity integer default 1,unit_price integer);
    create table settlements(id bigint generated always as identity,order_id bigint,book_id bigint,status text,cancelled_at timestamptz,
      recovery_required_at timestamptz,refund_reason text,updated_at timestamptz,
      seller_user_id uuid,order_item_id bigint,sale_amount integer,fee_percent numeric,fee_amount integer,net_amount integer,box_cost_deducted integer,
      scheduled_date date,bank_name text,account_number text,account_number_ciphertext text,account_number_last4 text,account_holder text,
      unique(order_id,book_id));
    create table shipments(id bigint primary key,user_id uuid,pickup_date date,fee_policy_version text,is_direct_purchase boolean default false,
      settlement_bank_name text,settlement_account_number_ciphertext text,settlement_account_last4 text,settlement_account_holder text,
      box_count integer default 0,box_cost_charged integer default 0);
    create table member_settlement_accounts(id bigint,user_id uuid,is_default boolean,created_at timestamptz,
      bank_name text,account_number text,account_number_ciphertext text,account_number_last4 text,account_holder text);
    create table manual_settlements(book_id bigint,status text);
    create function get_account_last4(text) returns text language sql as $$select right($1,4)$$;
    create function mask_account_number(text) returns text language sql as $$select '****'||$1$$;
    create function calculate_settlement_fee_percent(integer,date,text) returns numeric language sql as $$select 45::numeric$$;
    create function next_settlement_date(timestamptz) returns date language sql as $$select (date_trunc('month',$1)+interval '1 month')::date$$;
    create table member_coupons(id bigint primary key,used_at timestamptz,used_order_id bigint,status text,expires_at timestamptz,updated_at timestamptz);
    create table reviews(id bigint primary key,order_id bigint);
    create table point_lots(id bigint primary key,user_id uuid,remaining integer,expires_at timestamptz,voided_at timestamptz,void_reason text,review_id bigint);
    create table point_usages(id bigint primary key,lot_id bigint,order_id bigint,amount integer,restored_at timestamptz);
    create table point_transactions(user_id uuid,amount integer,kind text,order_id bigint,lot_id bigint,review_id bigint,note text);
    grant usage on schema public,auth to authenticated;
    select set_config('app.is_admin','true',false);
    select set_config('app.uid','${adminId}',false);
  `);
  const previous = await readFile(new URL("../supabase/migrations/20260824070040_refund_request_hold_auto_confirm.sql",import.meta.url),"utf8");
  for (const name of ["admin_refund_order_items","admin_refund_order","admin_resolve_refund_request"]) {
    const match = previous.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`,"i"));
    assert.ok(match, `real existing function ${name}`);
    await db.exec(match[0]);
  }
  for(const [file,names] of [
    ['20260902111905_member_points.sql',['restore_points_for_order','reclaim_review_points','sync_points_on_order_status']],
    ['20260902044155_return_hold_release_guard.sql',['release_books_on_order_cancel']],
    ['20260824063025_return_pickup_flow.sql',['books_assert_no_active_order_on_discard']],
  ]){
    const source=await readFile(new URL(`../supabase/migrations/${file}`,import.meta.url),'utf8');
    for(const name of names){
      const match=source.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`,'i'));
      assert.ok(match,`real existing trigger function ${name}`);await db.exec(match[0]);
    }
  }
  await db.exec(`create trigger trg_orders_sync_points after update of status on orders for each row execute function sync_points_on_order_status();
    create trigger guard_discard before update on books for each row execute function books_assert_no_active_order_on_discard();
    create trigger trg_release_books_on_order_cancel after update of status on orders for each row execute function release_books_on_order_cancel();`);
  await db.exec(await readFile(new URL("../supabase/migrations/20260914080709_return_inspection_before_refund.sql",import.meta.url),"utf8"));
  await db.exec(await readFile(new URL("../supabase/migrations/20260916034948_add_no_return_refund_flow.sql",import.meta.url),"utf8"));
  const settlementSource=await readFile(new URL("../supabase/migrations/20260910054749_pickup_fee_policy_versions.sql",import.meta.url),"utf8");
  await db.exec(settlementSource.match(/CREATE OR REPLACE FUNCTION public\.create_settlements_for_order\([\s\S]*?\$function\$\s*;/)[0]);
  await db.exec(await readFile(new URL("../supabase/migrations/20261005134046_delivered_defect_no_return_refund.sql",import.meta.url),"utf8"));
  await db.exec(await readFile(new URL("../supabase/migrations/20261005145939_member_refund_request_items.sql",import.meta.url),"utf8"));
});
after(async () => { await db.close(); });

test("품목 지정 구매자 신청도 기존 정산 생성 보류 가드와 연결된다",async()=>{
  const order=await fixture({settlements:false});
  await query("select set_config('app.uid',$1,false)",[buyerId]);
  try {
    await rpc("request_member_refund",[order.id,"답이 이미 적힌 교재가 도착했습니다.",[order.ids[0]]]);
  } finally { await query("select set_config('app.uid',$1,false)",[adminId]); }
  // 정산 대상 상태로 넘어가더라도 미해소 신청이 있으면 생성하지 않는다.
  await query("update orders set status='confirmed',confirmed_at=now() where id=$1",[order.id]);
  const result=await rpc("create_settlements_for_order",[order.id]);
  assert.equal(result.reason,"refund_on_hold");
  assert.equal((await query("select count(*)::int n from settlements where order_id=$1",[order.id]))[0].n,0);
});

test("도착·검수 전 차단, 일부 도착 차단, 승인만으로 금전·재고 불변, 23,000→17,000원",async()=>{
  const order = await fixture(); const id = await start(order);
  await assert.rejects(claim(id),/검수/);
  await assert.rejects(rpc("admin_refund_order_items",[order.id,order.ids]),/RETURN_INSPECTION_REQUIRED/);
  await assert.rejects(rpc("admin_refund_order",[order.id]),/RETURN_INSPECTION_REQUIRED/);
  await assert.rejects(rpc("admin_resolve_refund_request",[order.id]),/진행 중인 반품/);
  await receive(id,[order.ids[0]]); await assert.rejects(approve(id),/모든 반품/);
  await receive(id,[order.ids[1]]);
  const result = await approve(id); assert.equal(result.refund_amount,17000); assert.equal(result.shipping_deduction,6000);
  assert.equal((await query("select refunded_amount from orders where id=$1",[order.id]))[0].refunded_amount,0);
  assert.ok((await query("select status from books where id=any($1)",[order.ids])).every(row=>row.status === "reserved"));
  const attempt = await claim(id); assert.ok(attempt.token); assert.equal(attempt.whole_order,true); assert.ok(attempt.claimed_at);
  await assert.rejects(claim(id),/한 번만/);
  await assert.rejects(rpc("admin_complete_return_refund",[id,adminId]),/토큰/);
  const completion = await rpc("admin_complete_return_refund",[id,attempt.token]); assert.equal(completion.refund_amount,17000);
  const again = await rpc("admin_complete_return_refund",[id,attempt.token]); assert.equal(again.already_completed,true);
  const stored = (await query("select status,refunded_amount,refund_request_resolved_at from orders where id=$1",[order.id]))[0];
  assert.equal(stored.status,"refunded"); assert.equal(stored.refunded_amount,17000); assert.ok(stored.refund_request_resolved_at);
  assert.ok((await query("select status from books where id=any($1)",[order.ids])).every(row=>row.status === "on_sale"));
});

test("무료배송·하자·발송 전 취소·쿠폰 적용 주문의 실제 결제잔액 기준",async()=>{
  for (const scenario of [
    { total:50000,shipping:0,expected:44000 },
    { total:23000,reason:"seller_fault",expected:23000 },
    { total:23000,status:"preparing",expected:23000 },
    { total:19000,coupon:true,expected:13000 },
  ]) {
    const order=await fixture(scenario); const id=await start(order,scenario.reason);
    if (scenario.status!=="preparing") await receive(id,order.ids);
    assert.equal((await approve(id)).refund_amount,scenario.expected);
    const attempt=await claim(id); await rpc("admin_complete_return_refund",[id,attempt.token]);
    if (scenario.coupon) assert.equal((await query("select status from member_coupons where id=$1",[order.id]))[0].status,"available");
  }
});

test("배송완료·운송장 주문도 미발송 누락은 회수 없이 즉시 전액 환불 승인",async()=>{
  const order=await fixture({total:18000,prices:[7500,7500]});
  await query("update orders set tracking_number='540000000000' where id=$1",[order.id]);
  const prepared=await rpc("admin_prepare_no_return_refund",[
    order.id,order.ids,"실제 포장 누락으로 구매자에게 전달되지 않음",true,null,null,
  ]);
  assert.equal(prepared.requires_return,false);
  assert.equal(prepared.status,"approved");
  assert.equal(prepared.refund_amount,18000);
  assert.equal(prepared.shipping_deduction,0);
  const stored=(await query("select status,requires_return,received_at,refund_amount from order_return_cases where id=$1",[prepared.return_id]))[0];
  assert.equal(stored.status,"approved");
  assert.equal(stored.requires_return,false);
  assert.equal(stored.received_at,null);
  assert.equal(stored.refund_amount,18000);
  const attempt=await claim(prepared.return_id);
  const completion=await rpc("admin_complete_return_refund",[prepared.return_id,attempt.token]);
  assert.equal(completion.refund_amount,18000);
  assert.ok((await query("select status from books where id=any($1)",[order.ids])).every(row=>row.status==="on_sale"));
});

test("일부 미발송 누락은 회수비 0원과 수동 금액 근거를 강제",async()=>{
  const order=await fixture({total:18000,prices:[7500,7500]});
  await assert.rejects(rpc("admin_prepare_no_return_refund",[
    order.id,[order.ids[0]],"한 권만 포장 누락으로 미배송",false,null,null,
  ]),/계산 근거/);
  assert.equal((await query("select count(*)::int n from order_return_cases where order_id=$1",[order.id]))[0].n,0);
  const prepared=await rpc("admin_prepare_no_return_refund",[
    order.id,[order.ids[0]],"한 권만 포장 누락으로 미배송",false,7500,"누락된 선택 품목 결제액 전액 환불",
  ]);
  assert.equal(prepared.refund_amount,7500);
  assert.equal(prepared.shipping_deduction,0);
  assert.equal((await query("select requires_return from order_return_cases where id=$1",[prepared.return_id]))[0].requires_return,false);
});

test("일부 반품은 직접 계산 필수, 선택 품목만 환불·정산 취소, 다음 반품과 분리",async()=>{
  const order=await fixture({total:18000}); const id=await start(order,"buyer_remorse",[order.ids[0]]);
  await assert.rejects(start(order),/진행 중/);
  await receive(id,[order.ids[0]]); await assert.rejects(approve(id),/계산 근거/);
  await assert.rejects(approve(id,{amount:19000,fee:0,note:"테스트 계산 근거"}),/초과/);
  await approve(id,{amount:5000,fee:3000,note:"선택 상품 할인 배분 및 편도 배송비 차감",restock:false});
  const attempt=await claim(id); await rpc("admin_complete_return_refund",[id,attempt.token]);
  const items=await query("select refunded_at,restock_held_at from order_items where order_id=$1 order by id",[order.id]);
  assert.ok(items[0].refunded_at); assert.ok(items[0].restock_held_at); assert.equal(items[1].refunded_at,null);
  assert.equal((await query("select status from orders where id=$1",[order.id]))[0].status,"delivered");
  assert.equal((await query("select status from settlements where book_id=$1",[order.ids[1]]))[0].status,"pending");
  const second=await start(order,"buyer_remorse",[order.ids[1]]); await receive(second,[order.ids[1]]);
  await assert.rejects(approve(second),/계산 근거/);
});

test("구매확정 후 회수 면제: 선택 교재만 환불·미지급 정산 취소·재판매 제외, 재실행은 멱등",async()=>{
  const order=await fixture({status:"confirmed",total:11000,shipping:0,prices:[5500,5500]});
  const prepared=await rpc("admin_prepare_delivered_no_return_refund",[
    order.id,[order.ids[0]],"모의고사 전체 풀이 흔적 확인, 반품 없이 환불",5500,"선택 17회 상품값 전액, 배송비 차감 없음",
  ]);
  const row=(await rpc("admin_get_order_returns",[order.id]))[0];
  assert.equal(row.return_waived,true); assert.equal(row.requires_return,false); assert.equal(row.restock,false);
  assert.equal(row.status,"approved"); assert.equal(row.received_at,null); assert.equal(row.shipping_deduction,0);
  assert.ok(row.items.every(item=>!item.received_at));
  assert.equal((await query("select refunded_amount from orders where id=$1",[order.id]))[0].refunded_amount,0);
  await assert.rejects(query("update order_return_cases set restock=true where id=$1",[prepared.return_id]),/order_return_waived_no_restock/);
  const attempt=await claim(prepared.return_id);
  const completed=await rpc("admin_complete_return_refund",[prepared.return_id,attempt.token]);
  assert.equal(completed.held_books,0); assert.equal(completed.discarded_books,1);
  assert.equal((await rpc("admin_complete_return_refund",[prepared.return_id,attempt.token])).already_completed,true);
  const items=await query("select b.status,b.is_public,oi.refunded_at,oi.restock_held_at from order_items oi join books b on b.id=oi.book_id where oi.order_id=$1 order by oi.id",[order.id]);
  assert.equal(items[0].status,"discarded"); assert.equal(items[0].is_public,false); assert.ok(items[0].refunded_at); assert.equal(items[0].restock_held_at,null);
  assert.equal(items[1].status,"reserved"); assert.equal(items[1].refunded_at,null);
  assert.deepEqual((await query("select status from settlements where order_id=$1 order by book_id",[order.id])).map(r=>r.status),["cancelled","pending"]);
  assert.equal((await query("select refunded_amount,status from orders where id=$1",[order.id]))[0].refunded_amount,5500);
  assert.equal((await query("select count(*)::int n from order_return_events where return_id=$1 and action='waived_inventory_excluded'",[prepared.return_id]))[0].n,1);
});

test("이미 지급한 구매확정 품목은 손실 확인 전 PG 실행 차단, 선택 정산만 회수 필요",async()=>{
  const order=await fixture({status:"confirmed",total:11000,shipping:0,prices:[5500,5500],settled:true});
  await query("update books set status='settled' where id=any($1)",[order.ids]);
  const prepared=await rpc("admin_prepare_delivered_no_return_refund",[order.id,[order.ids[0]],"풀이 완료된 모의고사 하자 확인·회수 면제",5500,"해당 교재 상품값 전액 환불"]);
  await assert.rejects(claim(prepared.return_id),/RECOVERY_REQUIRED_ACK/);
  assert.equal((await query("select status from order_return_cases where id=$1",[prepared.return_id]))[0].status,"approved");
  const attempt=await claim(prepared.return_id,null,true);
  await rpc("admin_complete_return_refund",[prepared.return_id,attempt.token]);
  assert.deepEqual((await query("select status from settlements where order_id=$1 order by book_id",[order.id])).map(r=>r.status),["recovery_required","completed"]);
  assert.deepEqual((await query("select status from books where id=any($1) order by id",[order.ids])).map(r=>r.status),["discarded","settled"]);
});

test("회수 면제는 하자·배송 상태·금액을 검증하고 승인 실패 또는 접수 취소 시 재고를 바꾸지 않음",async()=>{
  const unsent=await fixture({status:"preparing"});
  await assert.rejects(rpc("admin_prepare_delivered_no_return_refund",[unsent.id,unsent.ids,"회수 없는 환불 사유"]),/배송중/);
  const order=await fixture({status:"confirmed"});
  await assert.rejects(rpc("admin_prepare_delivered_no_return_refund",[order.id,[order.ids[0]],"필기 하자로 회수 면제"]),/계산 근거/);
  await assert.rejects(rpc("admin_prepare_delivered_no_return_refund",[order.id,[99999],"필기 하자로 회수 면제",5000,"선택 교재 결제금액 환불"]),/미환불 품목/);
  assert.equal((await query("select count(*)::int n from order_return_cases where order_id=$1",[order.id]))[0].n,0);
  const prepared=await rpc("admin_prepare_delivered_no_return_refund",[order.id,order.ids,"모든 교재 필기 하자로 회수 면제"]);
  assert.equal(prepared.refund_amount,23000); assert.equal(prepared.shipping_deduction,0);
  await rpc("admin_cancel_order_return",[prepared.return_id,"고객 협의로 환불 접수 정정"]);
  assert.ok((await query("select status from books where id=any($1)",[order.ids])).every(b=>b.status==="reserved"));
  assert.equal((await query("select refunded_amount from orders where id=$1",[order.id]))[0].refunded_amount,0);
});

test("회수 면제 진행 중 정산 생성 보류, 환불 후 선택 품목 제외·남은 품목만 생성 및 중복 방지",async()=>{
  const order=await fixture({status:"confirmed",total:11000,shipping:0,prices:[5500,5500],settlements:false});
  await query("insert into shipments(id,pickup_date,fee_policy_version,settlement_bank_name,settlement_account_last4,settlement_account_holder) values($1,'2026-09-01','legacy','테스트은행','1234','테스트 셀러')",[order.id]);
  await query("update books set shipment_id=$1 where id=any($2)",[order.id,order.ids]);
  await query("update orders set confirmed_at=now() where id=$1",[order.id]);
  const prepared=await rpc("admin_prepare_delivered_no_return_refund",[order.id,[order.ids[0]],"모의고사 풀이 확인으로 회수 면제",5500,"해당 회차 상품값 전액 환불"]);
  assert.equal((await rpc("create_settlements_for_order",[order.id])).reason,"refund_on_hold");
  assert.equal((await query("select count(*)::int n from settlements where order_id=$1",[order.id]))[0].n,0);
  const attempt=await claim(prepared.return_id); await rpc("admin_complete_return_refund",[prepared.return_id,attempt.token]);
  assert.equal((await rpc("create_settlements_for_order",[order.id])).inserted_count,1);
  const rows=await query("select book_id,status,sale_amount,net_amount from settlements where order_id=$1",[order.id]);
  assert.deepEqual(rows,[{book_id:order.ids[1],status:"pending",sale_amount:5500,net_amount:3025}]);
  assert.equal((await rpc("create_settlements_for_order",[order.id])).inserted_count,0);
});

test("실제 기존 트리거 유지: 포인트는 현금과 분리해 1회 복구, 후기 적립 회수, 전체 환불 재고 보류",async()=>{
  const order=await fixture({total:21000});
  await query('update orders set points_used=2000 where id=$1',[order.id]);
  await query("insert into point_lots(id,user_id,remaining,expires_at) values($1,$2,0,now()-interval '1 day')",[order.id,buyerId]);
  await query('insert into point_usages(id,lot_id,order_id,amount) values($1,$1,$1,2000)',[order.id]);
  await query('insert into reviews(id,order_id) values($1,$1)',[order.id]);
  await query("insert into point_lots(id,user_id,remaining,review_id) values($1,$2,500,$3)",[order.id+10000,buyerId,order.id]);
  const id=await start(order);await receive(id,order.ids);
  assert.equal((await approve(id,{restock:false})).refund_amount,15000);
  assert.equal((await query('select remaining from point_lots where id=$1',[order.id]))[0].remaining,0);
  const attempt=await claim(id);await rpc('admin_complete_return_refund',[id,attempt.token]);
  await rpc('admin_complete_return_refund',[id,attempt.token]);
  assert.equal((await query('select remaining from point_lots where id=$1',[order.id]))[0].remaining,2000);
  assert.equal((await query('select remaining from point_lots where id=$1',[order.id+10000]))[0].remaining,0);
  assert.equal((await query("select count(*)::int n from point_transactions where order_id=$1 and kind='order_restore'",[order.id]))[0].n,1);
  assert.ok((await query('select status,is_public from books where id=any($1)',[order.ids])).every(b=>b.status==='reserved'&&!b.is_public));
});

test("무통장 송금 확인·정산 손실 확인, 검수 보류와 0원 이하 차단",async()=>{
  const order=await fixture({method:"bank_transfer",settled:true}); const id=await start(order);
  await receive(id,order.ids); await rpc("admin_review_order_return",[id,false,"추가 필기 확인이 필요함"]);
  await assert.rejects(claim(id),/검수/); await approve(id);
  await assert.rejects(claim(id),/송금/); await assert.rejects(claim(id,"2026-09-13 송금 확인 12345"),/RECOVERY_REQUIRED_ACK/);
  const attempt=await claim(id,"2026-09-13 송금 확인 12345",true); await rpc("admin_complete_return_refund",[id,attempt.token]);
  assert.ok((await query("select status from settlements where order_id=$1",[order.id])).every(row=>row.status==="recovery_required"));
  const low=await fixture({total:5000}); const lowId=await start(low); await receive(lowId,low.ids);
  await assert.rejects(approve(lowId),/0원 이하/);
  const fault=await fixture(); const faultId=await start(fault,"seller_fault"); await receive(faultId,fault.ids);
  await assert.rejects(approve(faultId,{amount:17000,fee:6000,note:"잘못된 배송비 차감"}),/차감할 수 없습니다/);
});

test("환불 시작 뒤 접수 종결·재승인 차단, 실패는 보류 유지, 승인 후 금액 변경 차단",async()=>{
  const order=await fixture(); const id=await start(order); await receive(id,order.ids); await approve(id);
  await query("update orders set total_amount=total_amount-1 where id=$1",[order.id]);
  await assert.rejects(claim(id),/변경/); await query("update orders set total_amount=total_amount+1 where id=$1",[order.id]);
  const attempt=await claim(id);
  await assert.rejects(rpc("admin_cancel_order_return",[id,"운영자 접수 취소 요청"]),/실행한 반품/);
  await assert.rejects(approve(id),/검수 가능한/);
  await rpc("admin_flag_return_refund",[id,attempt.token,"PG 응답 유실 확인 필요"]);
  await query("update orders set refund_request_resolved_at=now() where id=$1",[order.id]);
  assert.equal((await query("select refund_request_resolved_at from orders where id=$1",[order.id]))[0].refund_request_resolved_at,null);
  await assert.rejects(query("update orders set status='confirmed' where id=$1",[order.id]),/구매확정/);
  await assert.rejects(rpc("admin_get_return_refund_attempt",[id]),/1분/);
  await query("update order_return_cases set claimed_at=now()-interval '2 minutes' where id=$1",[id]);
  assert.equal((await rpc("admin_get_return_refund_attempt",[id])).token,attempt.token);
});

test("RLS: 타 구매자 진행·내부 메모·토큰 비노출, 비관리자 쓰기·내부 환불 호출 차단",async()=>{
  const order=await fixture(); const id=await start(order);
  await db.exec(`set role authenticated; select set_config('app.is_admin','false',false); select set_config('app.uid','${buyerId}',false);`);
  assert.deepEqual(await query("select * from order_return_cases"),[]);
  const own=await rpc("get_my_order_return_progress"); assert.ok(own.some(row=>row.order_id===order.id));
  assert.ok(own.every(row=>!Object.hasOwn(row,"claim_token")&&!Object.hasOwn(row,"inspection_note")));
  await assert.rejects(rpc("admin_get_order_returns",[order.id]),/Admin access/);
  await assert.rejects(rpc("admin_receive_order_return",[id,order.ids]),/Admin access/);
  await assert.rejects(rpc("admin_prepare_no_return_refund",[order.id,order.ids,"미발송 확인 완료",false,null,null]),/Admin access/);
  await assert.rejects(rpc("admin_prepare_delivered_no_return_refund",[order.id,order.ids,"풀이 흔적 확인 회수 면제",null,null]),/Admin access/);
  await assert.rejects(query("update order_return_cases set status='approved' where id=$1",[id]),/permission denied/);
  await assert.rejects(query("select subook_refund_internal.admin_refund_order_items($1,$2)",[order.id,order.ids]),/permission denied/);
  await db.exec(`select set_config('app.uid','00000000-0000-0000-0000-000000000003',false);`);
  assert.deepEqual(await rpc("get_my_order_return_progress"),[]);
  await db.exec(`reset role; select set_config('app.is_admin','true',false); select set_config('app.uid','${adminId}',false);`);
});
