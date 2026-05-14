-- Phase 4 마이그레이션
--
-- 1. admin_update_order_status 화이트리스트 강화 + confirmed/preparing/refunded 전이 검증
--    → 운영자 실수로 paid → confirmed 점프 차단
-- 2. admin_confirm_payment(p_order_id, p_paid_amount) RPC 추가
--    → 입금확인 시 금액 검증 + 동일 책 active order 재검증
--    → P0 #4 (pending 제외) 정책의 후속 가드: 두 사용자가 동시 pending 상태에서
--      먼저 paid 전이하는 사람이 우승, 나중 시도는 reject

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) admin_update_order_status: 화이트리스트 + 추가 전이 검증
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_update_order_status(
  p_order_id bigint,
  p_status text,
  p_tracking_number text default null,
  p_tracking_carrier text default 'CJ대한통운'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 화이트리스트: 허용 status 외 진입 차단
  if p_status not in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed', 'cancelled') then
    raise exception 'Invalid status: % (허용: paid/preparing/shipping/delivered/confirmed/cancelled)', p_status;
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found';
  end if;

  -- 상태 전이 검증 (단방향 + 명시적 분기만)
  if p_status = 'paid' then
    -- 입금확인은 admin_confirm_payment 사용 권장 (금액 검증 + 재검증). 그러나 호환성을 위해 허용.
    if v_order.status not in ('pending') then
      raise exception 'Cannot mark as paid from status: %', v_order.status;
    end if;
  elsif p_status = 'preparing' then
    if v_order.status not in ('paid') then
      raise exception 'Cannot mark as preparing from status: %', v_order.status;
    end if;
  elsif p_status = 'shipping' then
    if v_order.status not in ('paid', 'preparing') then
      raise exception 'Cannot mark as shipping from status: %', v_order.status;
    end if;
  elsif p_status = 'delivered' then
    if v_order.status not in ('shipping') then
      raise exception 'Cannot mark as delivered from status: %', v_order.status;
    end if;
  elsif p_status = 'confirmed' then
    -- confirmed는 delivered에서만 가능. paid → confirmed 직행 차단 (운영 실수 방지).
    if v_order.status not in ('delivered') then
      raise exception 'Cannot mark as confirmed from status: %. 환불은 admin_refund_order를 사용하세요.', v_order.status;
    end if;
  elsif p_status = 'cancelled' then
    if v_order.status not in ('pending', 'paid', 'preparing') then
      raise exception 'Cannot cancel from status: %. 배송 시작 이후는 admin_refund_order를 사용하세요.', v_order.status;
    end if;
  end if;

  update public.orders
  set
    status = p_status,
    payment_status = case
      when p_status = 'paid' then 'paid'
      when p_status = 'cancelled' then
        case when payment_status = 'paid' then 'refunded' else payment_status end
      else payment_status
    end,
    tracking_number = coalesce(p_tracking_number, tracking_number),
    tracking_carrier = coalesce(p_tracking_carrier, tracking_carrier),
    confirmed_at = case when p_status = 'confirmed' then now() else confirmed_at end,
    auto_confirm_at = case when p_status = 'delivered' then now() + interval '7 days' else auto_confirm_at end,
    updated_at = now()
  where id = p_order_id;

  -- paid 전이 시 쿠폰 복구 차단 (취소가 아니므로 그대로 유지)
  -- cancelled 시 쿠폰 복구
  if p_status = 'cancelled' and v_order.applied_member_coupon_id is not null then
    update public.member_coupons
    set used_at = null,
        used_order_id = null,
        status = case
          when expires_at is not null and expires_at < now() then 'expired'
          else 'available'
        end,
        updated_at = now()
    where id = v_order.applied_member_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'order_id', p_order_id, 'new_status', p_status);
end;
$$;

grant execute on function public.admin_update_order_status(bigint, text, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) admin_confirm_payment: 입금확인 RPC (금액 검증 + 동일 책 active 재검증)
--    P0 #4의 책 잠금 정책 'A' 후속 가드:
--    → 두 사용자가 동시 pending 상태에서 같은 책에 들어와 있을 때,
--       먼저 입금확인 누르는 어드민이 우승. 나중 시도는 다른 active order 검출로 reject.
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
  v_item record;
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

  -- 금액 검증 (생략 시 skip — 호환성 유지)
  if p_paid_amount is not null and p_paid_amount <> v_order.total_amount then
    raise exception '입금 금액(%원)이 주문 금액(%원)과 일치하지 않습니다.',
      p_paid_amount, v_order.total_amount;
  end if;

  -- 동일 책에 이미 paid 이상인 active order가 있으면 reject
  -- (P0 #4: pending끼리는 공존 허용. paid 전이 시점에 race 차단)
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

  -- paid 전이
  update public.orders
  set
    status = 'paid',
    payment_status = 'paid',
    updated_at = now()
  where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'new_status', 'paid',
    'verified_amount', v_order.total_amount
  );
end;
$$;

grant execute on function public.admin_confirm_payment(bigint, integer) to authenticated;

commit;
