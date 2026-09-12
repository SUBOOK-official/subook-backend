-- 테스트 빌더가 migration의 public 참조를 performance_test 스키마로 바꿔 삽입한다.
-- 운영 주문 테이블/트리거에는 쓰지 않는다. 전체 테스트는 ROLLBACK으로 종료한다.
begin;
create schema performance_test;
create table performance_test.orders (
  id bigint primary key, user_id uuid, shipping_recipient_phone text,
  paid_at timestamptz, pg_approved_at timestamptz, created_at timestamptz,
  total_amount integer, refunded_amount integer, payment_status text, status text, attribution jsonb
);
create table performance_test.order_items (order_id bigint, quantity integer, refunded_at timestamptz);
create function performance_test.is_admin_user() returns boolean language sql as
  $$ select current_setting('performance.is_admin',true) = 'true' $$;

-- @@PERFORMANCE_MIGRATION@@

select set_config('performance.is_admin','true',true);
insert into performance_test.orders(id,user_id,paid_at,created_at,total_amount,refunded_amount,payment_status,status,attribution) values
  (1,'11111111-1111-4111-8111-111111111111','2026-09-05 15:00Z','2026-09-01 10:00Z',10000,2000,'paid','confirmed','{"last_touch":{"source":"instagram","medium":"paid_social"}}'),
  (2,'11111111-1111-4111-8111-111111111111','2026-09-06 15:00Z','2026-09-06 15:00Z',5000,0,'paid','confirmed','{"last_touch":{"source":"instagram","medium":"social","click_id_types":["fbclid"]}}'),
  (3,null,'2026-09-07 15:00Z','2026-09-07 15:00Z',8000,0,'paid','preparing',null),
  (4,null,'2026-09-08 15:00Z','2026-09-08 15:00Z',9000,9000,'refunded','refunded',null),
  (5,null,null,'2026-09-08 15:00Z',1000000,0,'pending','cancelled',null),
  (6,null,'2026-09-05 14:59:59Z','2026-09-05 14:59:59Z',6000,0,'paid','confirmed',null),
  (7,null,'2026-09-12 15:00Z','2026-09-12 15:00Z',1000000,0,'paid','preparing',null),
  (8,null,null,'2026-09-09 15:00Z',1000000,0,'refunded','cancelled',null),
  (9,null,'2026-09-11 15:00Z','2026-09-11 15:00Z',3000,0,'refunded','refunded',null);
-- 같은 비회원의 포맷이 다른 연락처는 하나로 센다.
update performance_test.orders set shipping_recipient_phone = '010-0000-0001' where id=3;
update performance_test.orders set shipping_recipient_phone = '01000000001' where id=4;
insert into performance_test.order_items values
  (1,3,null),(1,1,'2026-09-10 09:00Z'),(2,2,null),(3,1,null),(4,1,'2026-09-09 09:00Z'),
  (5,100,null),(6,2,null),(7,100,null),(8,100,null),(9,1,null);

do $test$
declare r jsonb; item jsonb; orders_count bigint;
begin
  r := performance_test.admin_performance_report('2026-09-06','2026-09-12');
  assert (r#>>'{current,grossRevenue}')::numeric = 35000, 'gross includes refunded, excludes unpaid and outside KST';
  assert (r#>>'{current,refunds}')::numeric = 14000, 'partial plus full refund fallback';
  assert (r#>>'{current,netRevenue}')::numeric = 21000;
  assert (r#>>'{current,orders}')::integer = 5, 'order join must not duplicate multi-item order';
  assert (r#>>'{current,soldQuantity}')::integer = 6;
  assert (r#>>'{current,paidQuantity}')::integer = 9;
  assert (r#>>'{current,buyers}')::integer = 3, 'member dedupe, guest phone dedupe, missing contact fallback';
  assert (r#>>'{current,aov}')::numeric = 7000;
  assert (r#>>'{previous,grossRevenue}')::numeric = 6000;
  assert (r#>>'{previous,orders}')::integer = 1;
  assert (r#>>'{current,metaRevenue}')::numeric = 8000, 'organic Meta and fbclid alone are excluded';
  assert (r#>>'{current,metaOrders}')::integer = 1;
  assert (r#>>'{current,attributedOrders}')::integer = 2;
  assert (r->>'unverifiedPayments')::integer = 1;
  assert jsonb_array_length(r->'daily') = 7;
  assert (r#>>'{daily,0,date}') = '2026-09-06';
  assert (r#>>'{daily,0,orders}')::integer = 1;
  select sum((value->>'orders')::integer) into orders_count from jsonb_array_elements(r->'daily');
  assert orders_count=5, 'daily reconciles to summary';
  r := performance_test.admin_performance_report('2026-09-10','2026-09-10');
  assert (r#>>'{current,orders}')::integer = 0;
  assert (r#>'{current,aov}') = 'null'::jsonb, 'no-order AOV is unknown, not zero';
  assert jsonb_array_length(r->'daily')=1;
  begin perform performance_test.admin_performance_report('2026-09-12','2026-09-01'); raise exception 'range guard failed'; exception when invalid_parameter_value then null; end;
  begin perform performance_test.admin_performance_report('2025-01-01','2026-09-12'); raise exception 'limit guard failed'; exception when invalid_parameter_value then null; end;
  begin perform performance_test.admin_performance_report(null,'2026-09-12'); raise exception 'null guard failed'; exception when invalid_parameter_value then null; end;
  assert not has_function_privilege('anon','performance_test.admin_performance_report(date,date)','execute'), 'anon denied';
  perform set_config('performance.is_admin','false',true);
  begin perform performance_test.admin_performance_report('2026-09-06','2026-09-12'); raise exception 'admin guard failed'; exception when insufficient_privilege then null; end;
  perform set_config('performance.is_admin','true',true);
end;
$test$;

select 'PASS: KST boundaries, comparison, quantities, refund, buyer dedupe, attribution, empty period, validation, admin/anon guards' as result;
rollback;
