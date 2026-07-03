-- 결제 확인 시 곧바로 '상품 준비 중(preparing)'으로 — 'paid(결제완료)' 대기 단계 제거
--
-- 배경(2026-07-02 정책): PG(카드) 결제가 붙으면 결제 즉시 확정되므로 별도의 '결제완료'
-- 대기 단계가 불필요. 무통장(bank_transfer)은 입금대기(pending) → [입금확인] → 준비중,
-- PG는 결제 성공 시 곧바로 준비중으로 간다.
--
-- 변경: 결제 확정 두 경로가 기존 pending→'paid' 대신 pending→'preparing'으로 전이한다.
--   · admin_confirm_payment  = 무통장 입금확인(운영자)
--   · confirm_pg_payment     = PG(토스) 결제 승인 후(service_role 서버리스)
--   결제 부수효과(payment_status='paid', books→reserved, PG 메타 기록)는 그대로 이 전이에 유지.
--
-- 비파괴:
--   · orders.status CHECK 제약의 'paid' 값은 그대로 둔다(레거시 주문 호환 — 기존 paid 주문 존재).
--   · admin_update_order_status는 손대지 않는다(레거시 paid→preparing/shipping 경로 유지.
--     shipping은 이미 ('paid','preparing') 둘 다 허용하므로 신규 preparing→shipping 정상).
--   · CREATE OR REPLACE FUNCTION만 사용(시그니처 동일) — additive, 비파괴.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) admin_confirm_payment: 무통장 입금확인 → pending에서 곧바로 preparing
--    (base: 20260525180000_books_reserved_status.sql — status만 'paid'→'preparing')
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_confirm_payment(
  p_order_id bigint,
  p_paid_amount integer default null
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
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found';
  end if;
  if v_order.status <> 'pending' then
    raise exception 'Cannot confirm payment from status: % (pending만 허용)', v_order.status;
  end if;

  if p_paid_amount is not null and p_paid_amount <> v_order.total_amount then
    raise exception '입금 금액(%원)이 주문 금액(%원)과 일치하지 않습니다.',
      p_paid_amount, v_order.total_amount;
  end if;

  -- 동일 책에 이미 결제 확정된(pending/취소/환불 아닌) active order가 있으면 reject
  select array_agg(distinct o2.id), count(distinct o2.id)
    into v_conflict_orders, v_conflict_count
  from public.order_items oi
  inner join public.order_items oi2 on oi2.book_id = oi.book_id and oi2.order_id <> oi.order_id
  inner join public.orders o2 on o2.id = oi2.order_id
  where oi.order_id = p_order_id
    and o2.status not in ('pending', 'cancelled', 'refunded');

  if coalesce(v_conflict_count, 0) > 0 then
    raise exception '이미 다른 주문이 결제 확정된 책이 포함되어 있습니다. (충돌 주문: %)', v_conflict_orders;
  end if;

  -- ⚠ 변경: 입금확인 = 곧바로 준비중. payment_status는 그대로 paid로 기록(결제 사실 추적).
  update public.orders
  set
    status = 'preparing',
    payment_status = 'paid',
    updated_at = now()
  where id = p_order_id;

  -- 결제완료된 books를 reserved로 → storefront 즉시 비노출.
  update public.books
  set status = 'reserved'
  where id in (
    select oi.book_id from public.order_items oi where oi.order_id = p_order_id
  )
  and status = 'on_sale';

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'new_status', 'preparing',
    'verified_amount', v_order.total_amount
  );
end;
$$;

grant execute on function public.admin_confirm_payment(bigint, integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) confirm_pg_payment: 토스 승인 검증 후 → pending에서 곧바로 preparing
--    (base: 20260621000000_toss_pg_payment.sql — status만 'paid'→'preparing')
--    ⚠ 보안: authenticated/anon에서 회수, service_role만 execute (기존과 동일).
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

  -- 멱등성: 이미 이 paymentKey로 결제 처리된 주문 → 재호출(중복 리다이렉트/재시도)은
  --   에러 대신 동일 성공 반환. (paymentKey가 다르면 아래 분기로 떨어져 거부)
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

  -- pending이 아니면(이미 다른 결제로 확정 / 취소 / 환불 / 만료) 거부.
  if v_order.status <> 'pending' then
    raise exception 'Cannot confirm payment from status: % (pending만 허용)', v_order.status;
  end if;

  -- 금액 검증: 토스 승인 금액 == 주문 총액. (위변조/금액조작 방어)
  if p_amount is null or p_amount <> v_order.total_amount then
    raise exception '결제 금액(%원)이 주문 금액(%원)과 일치하지 않습니다.',
      p_amount, v_order.total_amount;
  end if;

  -- 동일 책에 이미 확정된 active order가 있으면 reject.
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

  -- ⚠ 변경: PG 결제 승인 = 곧바로 준비중. payment_status=paid + PG 메타 기록.
  update public.orders
  set
    status = 'preparing',
    payment_status = 'paid',
    payment_key = p_payment_key,
    pg_provider = coalesce(p_provider, 'toss'),
    pg_approved_at = now(),
    pg_raw = coalesce(p_raw, pg_raw),
    updated_at = now()
  where id = v_order.id;

  -- 결제완료된 books를 reserved로 → storefront 즉시 비노출.
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
    'new_status', 'preparing',
    'verified_amount', v_order.total_amount
  );
end;
$$;

-- ⚠ 보안: 구매자(authenticated)가 직접 호출해 결제 없이 preparing으로 위조하는 것을 차단.
--   토스 승인을 검증한 service_role 서버리스만 호출할 수 있다.
revoke all on function public.confirm_pg_payment(text, text, integer, text, jsonb) from public;
revoke all on function public.confirm_pg_payment(text, text, integer, text, jsonb) from anon;
revoke all on function public.confirm_pg_payment(text, text, integer, text, jsonb) from authenticated;
grant execute on function public.confirm_pg_payment(text, text, integer, text, jsonb) to service_role;

-- (참고) get_member_dashboard_summary의 purchase_in_progress_count에 'preparing'을
-- 추가하려 했으나, 라이브 함수는 purchase_in_progress_count 컬럼이 없는 구버전
-- (2026040705, 21컬럼 — 2026041302가 기록상 applied이나 실제 미반영 드리프트)이라
-- 해당 없음. 구매 진행중 카운트는 프론트(publicMypageUtils/memberPortal) 로컬 계산이
-- 담당하며 거기에 'preparing'을 반영했다. 함수 업그레이드는 별도 드리프트 복구 작업.

notify pgrst, 'reload schema';
