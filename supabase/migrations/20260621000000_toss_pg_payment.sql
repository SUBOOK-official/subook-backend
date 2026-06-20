-- 토스페이먼츠 PG 결제 연동 — DB 토대 (Phase 0)
--
-- 배경: 사업자 등록 완료로 PG 연동 가능. 현재는 100% 계좌이체(admin_confirm_payment 수동 확인).
-- PG는 계좌이체와 "나란히" 추가한다 — 기존 흐름/함수는 건드리지 않는다.
--
-- 추가물:
--   1) orders에 PG 결제 메타 컬럼 (payment_key 등) — additive, NOT NULL 없음(비파괴).
--   2) confirm_pg_payment RPC — 토스 결제 "승인"이 서버에서 검증된 뒤 호출되어
--      admin_confirm_payment와 "동일한" pending→paid + books=reserved 전이를 일으킨다.
--
-- ⚠ 보안 핵심: confirm_pg_payment는 authenticated(구매자)에게 grant하지 않는다.
--   구매자가 직접 호출해 "결제 없이" 자기 주문을 paid로 위조하는 걸 막기 위해
--   PUBLIC/authenticated에서 execute를 회수하고 service_role에만 부여한다.
--   호출자는 토스 /confirm(secretKey)으로 실제 승인을 검증한 신뢰된 서버리스뿐이다.
--
-- 비파괴: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE FUNCTION (시그니처 신규).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) orders PG 결제 메타 컬럼 (additive)
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists payment_key text,
  add column if not exists pg_provider text,
  add column if not exists pg_approved_at timestamptz,
  add column if not exists pg_raw jsonb;

comment on column public.orders.payment_key is '토스 paymentKey — 결제 취소(환불) 시 /v1/payments/{paymentKey}/cancel에 필요';
comment on column public.orders.pg_provider is 'PG 제공자 (toss 등). 계좌이체 주문은 NULL';
comment on column public.orders.pg_approved_at is 'PG 결제 승인 시각';
comment on column public.orders.pg_raw is '토스 승인 응답 원본 (감사/디버깅용)';

-- 동일 paymentKey가 두 주문에 붙는 것을 방지 (paymentKey ↔ order 1:1 방어).
create unique index if not exists uq_orders_payment_key
  on public.orders (payment_key)
  where payment_key is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) confirm_pg_payment: 토스 승인 검증 후 호출되는 paid 전이 RPC
--    admin_confirm_payment(20260525180000_books_reserved_status)의 전이 로직을
--    그대로 복제 + 멱등성 + 금액검증.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.confirm_pg_payment(
  p_order_number text,
  p_payment_key text,
  p_amount integer,
  p_provider text default 'toss',
  p_raw jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_conflict_count integer;
  v_conflict_orders bigint[];
begin
  if p_payment_key is null or btrim(p_payment_key) = '' then
    raise exception 'payment_key required';
  end if;
  if p_order_number is null or btrim(p_order_number) = '' then
    raise exception 'order_number required';
  end if;

  select * into v_order from public.orders
  where order_number = p_order_number
  for update;
  if not found then
    raise exception 'Order not found: %', p_order_number;
  end if;

  -- 멱등성: 이미 이 paymentKey로 결제완료된 주문 → 재호출(중복 리다이렉트/네트워크 재시도)은
  --   에러 대신 동일 성공을 반환한다. (paymentKey가 다르면 아래 분기로 떨어져 거부)
  if v_order.payment_status = 'paid' and v_order.payment_key = p_payment_key then
    return jsonb_build_object(
      'success', true,
      'idempotent', true,
      'order_id', v_order.id,
      'order_number', v_order.order_number,
      'new_status', v_order.status,
      'verified_amount', v_order.total_amount
    );
  end if;

  -- pending이 아니면(이미 다른 결제로 paid / 취소 / 환불 / 만료) 거부.
  if v_order.status <> 'pending' then
    raise exception 'Cannot confirm payment from status: % (pending만 허용)', v_order.status;
  end if;

  -- 금액 검증: 토스 승인 금액 == 주문 총액. (위변조/금액조작 방어)
  if p_amount is null or p_amount <> v_order.total_amount then
    raise exception '결제 금액(%원)이 주문 금액(%원)과 일치하지 않습니다.',
      p_amount, v_order.total_amount;
  end if;

  -- 동일 책에 이미 paid 이상인 active order가 있으면 reject.
  -- (admin_confirm_payment와 동일 — pending끼리는 공존 허용, 먼저 결제된 쪽이 책을 가져간다)
  select array_agg(distinct o2.id), count(distinct o2.id)
    into v_conflict_orders, v_conflict_count
  from public.order_items oi
  inner join public.order_items oi2 on oi2.book_id = oi.book_id and oi2.order_id <> oi.order_id
  inner join public.orders o2 on o2.id = oi2.order_id
  where oi.order_id = v_order.id
    and o2.status not in ('pending', 'cancelled', 'refunded');

  if coalesce(v_conflict_count, 0) > 0 then
    raise exception '이미 다른 주문이 결제 확정된 책이 포함되어 있습니다. (충돌 주문: %)', v_conflict_orders;
  end if;

  -- paid 전이 + PG 메타 기록
  update public.orders
  set
    status = 'paid',
    payment_status = 'paid',
    payment_key = p_payment_key,
    pg_provider = coalesce(p_provider, 'toss'),
    pg_approved_at = now(),
    pg_raw = coalesce(p_raw, pg_raw),
    updated_at = now()
  where id = v_order.id;

  -- 결제완료된 books를 reserved로 → storefront 즉시 비노출 (admin_confirm_payment와 동일).
  update public.books
  set status = 'reserved'
  where id in (
    select oi.book_id from public.order_items oi where oi.order_id = v_order.id
  )
  and status = 'on_sale';

  return jsonb_build_object(
    'success', true,
    'idempotent', false,
    'order_id', v_order.id,
    'order_number', v_order.order_number,
    'new_status', 'paid',
    'verified_amount', v_order.total_amount
  );
end;
$$;

-- ⚠ 보안: 구매자(authenticated)가 직접 호출해 결제 없이 paid로 위조하는 것을 차단.
--   토스 승인을 검증한 service_role 서버리스만 호출할 수 있다.
revoke all on function public.confirm_pg_payment(text, text, integer, text, jsonb) from public;
revoke all on function public.confirm_pg_payment(text, text, integer, text, jsonb) from anon;
revoke all on function public.confirm_pg_payment(text, text, integer, text, jsonb) from authenticated;
grant execute on function public.confirm_pg_payment(text, text, integer, text, jsonb) to service_role;

notify pgrst, 'reload schema';
