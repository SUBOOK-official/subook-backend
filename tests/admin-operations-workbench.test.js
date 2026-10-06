import { before, after, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const admin = "00000000-0000-0000-0000-000000000001";
const member = "00000000-0000-0000-0000-000000000002";
const q = async (sql, params = []) => (await db.query(sql, params)).rows;
async function login(isAdmin) { await q("select set_config('app.admin',$1,false),set_config('app.uid',$2,false)",[String(isAdmin),isAdmin ? admin : member]); }
const rpc = async (sql, params = []) => (await q(`select ${sql} as result`,params))[0].result;

before(async () => {
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key);
    insert into auth.users values('${admin}'),('${member}');
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.uid',true),'')::uuid$$;
    create function public.is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('app.admin',true)='true',false)$$;
    create table member_profiles(user_id uuid primary key,name text,email text,phone text,created_at timestamptz,phone_verified_at timestamptz,verified_phone text);
    create table orders(id bigint primary key,order_number text,user_id uuid,status text,payment_method text,payment_status text,
      paid_at timestamptz,pg_approved_at timestamptz,subtotal int,shipping_fee int,discount_amount int,coupon_discount_amount int,points_used int,
      applied_member_coupon_id bigint,total_amount int,item_count int,tracking_number text,tracking_carrier text,
      shipping_recipient_name text,shipping_recipient_phone text,shipping_postal_code text,shipping_address_line1 text,shipping_address_line2 text,shipping_memo text,
      confirmed_at timestamptz,auto_confirm_at timestamptz,created_at timestamptz default now(),updated_at timestamptz default now(),
      refund_requested_at timestamptz,refund_request_reason text,refunded_at timestamptz,refund_reason text,refund_request_resolved_at timestamptz,refunded_amount int,
      refund_bank_name text,refund_account_number text,refund_account_holder text,return_tracking_number text,return_registered_at timestamptz,return_recovered_at timestamptz);
    create table products(id bigint primary key,title text,cover_image_url text);
    create table pickup_requests(id bigint primary key,user_id uuid,request_number text,status text,pickup_recipient_name text,pickup_recipient_phone text,
      pickup_postal_code text,pickup_address_line1 text,pickup_address_line2 text,pickup_memo text,pickup_email text,pickup_entrance_password text,
      desired_pickup_date date,expected_book_count int,box_count int,item_count int,tracking_number text,tracking_carrier text,cj_request_id text,
      cj_pickup_registered_at timestamptz,cj_tracking_status text,cj_tracking_status_code text,cj_tracking_last_checked_at timestamptz,
      box_waybills jsonb,box_type_codes text[],created_at timestamptz default now(),updated_at timestamptz,merged_into_id bigint);
    create table shipments(id bigint primary key,pickup_request_id bigint,seller_name text,status text,created_at timestamptz default now());
    create table books(id bigint primary key,product_id bigint,shipment_id bigint,title text,status text,serial_number int,location text,price int,created_at timestamptz default now());
    create table order_items(id bigint primary key,order_id bigint,book_id bigint,product_id bigint,title text,option_label text,condition_grade text,cover_image_url text,
      quantity int,unit_price int,total_price int,refunded_at timestamptz,refund_amount int,refund_reason text,restock_held_at timestamptz);
    create table direct_sale_products(product_id bigint);
    create table pickup_items(id bigint,pickup_request_id bigint,title text,subject text,brand text,book_type text,published_year int,instructor_name text,original_price int,condition_memo text,is_manual_entry boolean);
    create table pickup_logistics_events(id bigint,pickup_request_id bigint,event_type text,status text,tracking_number text,status_code text,status_text text,error_message text,created_at timestamptz);
    create table settlements(id bigint primary key,order_id bigint,order_item_id bigint,book_id bigint,net_amount int,status text,completed_at timestamptz,created_at timestamptz default now(),bank_name text,account_number text,account_holder text);
    create table notification_logs(id bigint primary key,notification_type text,status text,created_at timestamptz);
    create table coupons(id bigint primary key,title text,code text,is_active boolean,valid_from timestamptz,valid_until timestamptz,total_quantity int,issued_count int,created_at timestamptz default now()); create table notices(id bigint primary key,title text); create table faqs(id bigint primary key,title text);
    create table event_subscriptions(event_key text,created_at timestamptz);
    create table book_change_logs(id bigint primary key,book_id bigint,field text,changed_by uuid,changed_at timestamptz,old_value text,new_value text);
    create table product_status_logs(id bigint primary key,product_id bigint,changed_by uuid,changed_at timestamptz,old_status text,new_status text);
    grant usage on schema public,auth to authenticated;
    grant select on settlements to authenticated;
  `);
  await db.exec(await readFile(new URL("../supabase/migrations/20261006064146_admin_operations_workbench.sql",import.meta.url),"utf8"));
  await db.exec(await readFile(new URL("../supabase/migrations/20261006072852_admin_coupon_operation_tags.sql",import.meta.url),"utf8"));
  await login(true);
  await db.exec(`
    insert into coupons(id,title,is_active,valid_until,issued_count) values(1,'만료 쿠폰',true,now()-interval '1 day',0),(2,'CS 쿠폰',true,null,0);
    insert into admin_coupon_tags values(2,'cs','응대 보상');
    insert into member_profiles(user_id,name) values('${member}','동명이인');
    insert into products values(1,'수학 교재',null);
    insert into books(id,product_id,title,status,price,created_at) values(1,1,'수학 교재','on_sale',10000,now()-interval '120 days'),(2,1,'수학 교재','on_sale',15000,now()-interval '120 days');
    insert into orders(id,order_number,user_id,status,total_amount,created_at,refund_requested_at) values
      (1,'OLD-REFUND','${member}','delivered',10000,'2026-01-01',now()),
      (2,'RESOLVED','${member}','delivered',15000,now(),now()),
      (3,'SHIP',null,'preparing',15000,now()-interval '3 days',null),
      (4,'KST',null,'confirmed',10000,'2026-09-28T15:00:00Z',null);
    update orders set refund_request_resolved_at=now() where id=2;
    insert into order_items(id,order_id,book_id,product_id,title,quantity,unit_price,total_price) values(1,1,1,1,'수학 교재',1,10000,10000);
    update order_items set refunded_at=now(),refund_amount=10000,restock_held_at=now() where id=1;
    insert into pickup_requests(id,user_id,request_number,status,box_type_codes) values(1,'${member}','P1','pending',array['SMALL']),(2,null,'P2','pending',array['SMALL']);
    insert into settlements(id,order_id,order_item_id,book_id,net_amount,status,completed_at) values(1,1,1,1,5500,'completed',now());
    insert into order_items(id,order_id,product_id,title,quantity) values(2,3,1,'피킹 교재',1);
    insert into event_subscriptions values('event-a',now()),('event-b',now()),('event-a',now());
  `);
});
after(() => db.close());

test("새 읽기 RPC는 익명과 일반 회원 접근을 거절", async () => {
  await db.exec("set role anon");
  await assert.rejects(rpc("list_admin_work_orders()"),/permission denied/);
  await db.exec("reset role; set role authenticated"); await login(false);
  for (const fn of ["list_admin_work_orders()","admin_operation_queue()","admin_inventory_ageing()","admin_settlement_exceptions()","admin_subscription_events()","admin_operation_history()","admin_set_fulfillment_check(3,2,true)","admin_list_work_coupons()"])
    await assert.rejects(rpc(fn),/Admin access required/);
  assert.deepEqual(await q("select * from list_admin_work_pickups()"),[]);
  assert.deepEqual(await q("select * from admin_cs_cases"),[]);
  await assert.rejects(q("insert into admin_cs_cases(title) values('불가')"),/row-level security/);
  await login(true);
});
test("환불/출고/보류 필터·회원 ID·날짜는 페이지를 자르기 전에 적용", async () => {
  const refunds = await rpc("list_admin_work_orders(p_view=>'refunds',p_limit=>1)");
  assert.equal(refunds.total_count,1); assert.equal(refunds.items[0].id,1);
  assert.deepEqual((await rpc("list_admin_work_orders(p_view=>'fulfillment')")).items.map((r)=>r.id),[3]);
  assert.deepEqual((await rpc("list_admin_work_orders(p_view=>'restock')")).items.map((r)=>r.id),[1]);
  assert.equal((await rpc("list_admin_work_orders(p_user_id=>$1)",[member])).total_count,2);
  assert.deepEqual((await rpc("list_admin_work_orders(p_from_date=>'2026-09-29',p_to_date=>'2026-09-29')")).items.map((r)=>r.id),[4]);
  assert.equal((await rpc("list_admin_work_orders(p_order_id=>1)")).items[0].order_number,'OLD-REFUND');
});
test("수거는 대상 ID와 회원 ID로 정확히 연결하고 박스 규격 유지", async () => {
  assert.deepEqual((await q("select * from list_admin_work_pickups(p_user_id=>$1)",[member])).map((r)=>r.id),[1]);
  const rows=await q("select * from list_admin_work_pickups(p_request_id=>2)");
  assert.deepEqual(rows[0].box_type_codes,['SMALL']); assert.equal(rows[0].total_count,1);
});
test("재고·정산 예외·업무 큐 조회는 기존 금액을 변경하지 않음", async () => {
  const before=await q("select net_amount,status from settlements");
  const inventory=await rpc("admin_inventory_ageing(90)");
  assert.equal(inventory.quantity,1);
  const exceptions=await rpc("admin_settlement_exceptions()"); assert.equal(exceptions.items[0].net_amount,5500);
  assert.ok((await rpc("admin_operation_queue()")).items.some((r)=>r.category==='환불 신청'));
  assert.deepEqual(await q("select net_amount,status from settlements"),before);
  assert.equal((await rpc("admin_subscription_events()")).length,2);
});
test("CS 동시 수정은 updated_at 비교로 차단, 이력에는 개인정보 값 미복제", async () => {
  const row=(await q("insert into admin_cs_cases(title,contact,order_id) values('환불 문의','010-private',1) returning *"))[0];
  const changed=await q("update admin_cs_cases set note='확인 중' where id=$1 and updated_at=$2 returning *",[row.id,row.updated_at]);
  assert.equal(changed.length,1);
  assert.equal((await q("update admin_cs_cases set note='오래된 수정' where id=$1 and updated_at=$2 returning *",[row.id,row.updated_at])).length,0);
  const events=await rpc("admin_operation_history(p_entity=>'admin_cs_cases')");
  assert.ok(events.total_count>=2); assert.ok(!JSON.stringify(events).includes('010-private'));
  await login(false); assert.deepEqual(await q("select * from admin_cs_cases"),[]);
  assert.deepEqual(await q("select * from admin_operation_events"),[]);
  await assert.rejects(q("insert into admin_operation_events(entity_type,entity_id,action) values('orders','1','forged')"),/permission denied/);
  await login(true);
});
test("쿠폰 운영 분류·사용 기간은 전체 목록에서 페이지 전에 필터", async () => {
  assert.equal((await rpc("admin_list_work_coupons(p_category=>'cs')")).items[0].id,2);
  assert.equal((await rpc("admin_list_work_coupons(p_availability=>'expired')")).items[0].id,1);
  assert.equal((await rpc("admin_list_work_coupons(p_search=>'응대')")).total_count,1);
  await login(false); assert.deepEqual(await q("select * from admin_coupon_tags"),[]);
  await assert.rejects(q("insert into admin_coupon_tags values(1,'test','')"),/row-level security/);
  await login(true);
});

test("출고 체크는 유효한 품목만 허용하고 피킹 해제 시 포장을 해제", async () => {
  await assert.rejects(rpc("admin_set_fulfillment_check(3,p_packed=>true)"),/피킹/);
  await assert.rejects(rpc("admin_set_fulfillment_check(3,1,true)"),/유효한 출고 품목/);
  assert.deepEqual((await rpc("admin_set_fulfillment_check(3,2,true)")).picked_item_ids,[2]);
  assert.ok((await rpc("admin_set_fulfillment_check(3,p_packed=>true)")).packed_at);
  assert.equal((await rpc("admin_set_fulfillment_check(3,2,false)")).packed_at,null);
  await assert.rejects(rpc("admin_set_fulfillment_check(1,1,true)"),/출고 대기 상태/);
});

test("대량 작업 결과는 작성자만 갱신하고 일반 회원에게 노출하지 않음", async () => {
  const row=(await q("insert into admin_work_jobs(kind,label,total) values('csv','송장 CSV',2) returning *"))[0];
  await q("update admin_work_jobs set status='partial',done=2,failures='[{\"id\":2,\"message\":\"실패\"}]' where id=$1",[row.id]);
  await assert.rejects(q("update admin_work_jobs set done=3 where id=$1",[row.id]),/check constraint/);
  await login(false); assert.deepEqual(await q("select * from admin_work_jobs"),[]);
  assert.equal((await q("update admin_work_jobs set status='completed' where id=$1 returning id",[row.id])).length,0);
  await login(true);
});
