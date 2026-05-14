-- 환불 흐름 (P1 #15)
-- 정책: 구매확정(confirmed) 후에도 환불 가능. settlements 상태별 자동 처리.
--   - settlements.status='pending' or 'approved' → 'cancelled' (송금 안 함)
--   - settlements.status='completed' → 'recovery_required' (셀러로부터 회수 필요)
--   - 책 상태는 변경 없음 (이미 settled된 책 복구 시 이중 정산 위험)
--   - 쿠폰 자동 복구
--
-- 추가 작업: 정산 수수료 계산을 floor → round로 변경 (P2)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) orders에 환불 메타 컬럼 + 'refunded' 상태는 이미 허용
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists refunded_at timestamptz null,
  add column if not exists refund_reason text null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) settlements.status check 확장: cancelled, recovery_required
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.settlements
  drop constraint if exists settlements_status_check;
alter table public.settlements
  add constraint settlements_status_check
  check (status in ('pending', 'approved', 'completed', 'cancelled', 'recovery_required'));

alter table public.settlements
  add column if not exists cancelled_at timestamptz null,
  add column if not exists recovery_required_at timestamptz null,
  add column if not exists refund_reason text null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) admin_refund_order: 어드민이 주문 환불 처리
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_refund_order(
  p_order_id bigint,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_now timestamptz := now();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_cancelled_settlements integer := 0;
  v_recovery_settlements integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status in ('cancelled', 'refunded') then
    raise exception '이미 취소/환불된 주문입니다. (현재: %)', v_order.status;
  end if;

  -- 1) orders 환불 처리
  update public.orders
  set
    status = 'refunded',
    payment_status = case when payment_status = 'paid' then 'refunded' else payment_status end,
    refunded_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where id = p_order_id;

  -- 2) settlements 상태별 자동 처리
  update public.settlements
  set
    status = 'cancelled',
    cancelled_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where order_id = p_order_id
    and status in ('pending', 'approved');
  get diagnostics v_cancelled_settlements = row_count;

  update public.settlements
  set
    status = 'recovery_required',
    recovery_required_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where order_id = p_order_id
    and status = 'completed';
  get diagnostics v_recovery_settlements = row_count;

  -- 3) 쿠폰 복구
  if v_order.applied_member_coupon_id is not null then
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

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'cancelled_settlements', v_cancelled_settlements,
    'recovery_required_settlements', v_recovery_settlements,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

grant execute on function public.admin_refund_order(bigint, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) admin_complete_settlements: 'completed'/'cancelled'/'recovery_required' 외 상태 skip 확실히
--    이미 admin_complete_settlements는 'approved'만 처리하므로 자연 통과지만 명시 확인.
--    (변경 없음 — 그러나 향후 'cancelled' settlements가 admin UI에서 잘못 select되면
--    완료 처리되지 않음. settlement_id 필터로 보호)
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) 정산 수수료 계산: floor → round (회사/셀러 중립)
--    이미 settled된 정산은 변경하지 않음 (회고 적용 안 함).
-- ─────────────────────────────────────────────────────────────────────────────
-- create_settlements_for_order는 2026051306의 본체 사용.
-- 거기서 fee_amount = floor(...) → round(...)로 변경.
-- 기존 함수가 다른 반환 타입을 가질 수 있으므로 DROP 후 CREATE.
drop function if exists public.create_settlements_for_order(bigint);

create function public.create_settlements_for_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_item record;
  v_book record;
  v_shipment_pickup_date date;
  v_seller_user_id uuid;
  v_sale_amount integer;
  v_fee_percent numeric(5, 2);
  v_fee_amount integer;
  v_net_amount integer;
  v_scheduled_date date;
  v_inserted_count integer := 0;
begin
  select * into v_order from public.orders
    where id = p_order_id and status = 'confirmed';
  if not found then
    return jsonb_build_object('success', false, 'reason', 'order_not_confirmed');
  end if;

  v_scheduled_date := public.add_business_days(coalesce(v_order.confirmed_at::date, current_date), 3);

  for v_item in
    select oi.*, b.shipment_id, b.price as book_price
    from public.order_items oi
    inner join public.books b on b.id = oi.book_id
    where oi.order_id = p_order_id
  loop
    select * into v_book from public.books where id = v_item.book_id;
    select s.pickup_date, s.user_id into v_shipment_pickup_date, v_seller_user_id
      from public.shipments s where s.id = v_book.shipment_id;

    -- 자체매입 책(seller_user_id NULL)은 settlements 생성 skip
    if v_seller_user_id is null then
      continue;
    end if;

    v_sale_amount := coalesce(v_item.total_price, 0);
    if v_sale_amount <= 0 then
      continue;
    end if;

    v_fee_percent := public.calculate_settlement_fee_percent(v_shipment_pickup_date, v_item.unit_price);
    -- ⚠️ round로 변경 (이전: floor) — 정책 결정에 따른 변경
    v_fee_amount := round(v_sale_amount * (v_fee_percent / 100))::integer;
    v_net_amount := v_sale_amount - v_fee_amount;

    if v_net_amount <= 0 then
      raise notice 'create_settlements_for_order: net_amount=0 skip order=% book=%', p_order_id, v_item.book_id;
      continue;
    end if;

    insert into public.settlements (
      seller_user_id, order_id, order_item_id, book_id,
      sale_amount, fee_percent, fee_amount, net_amount,
      status, scheduled_date
    )
    values (
      v_seller_user_id, p_order_id, v_item.id, v_item.book_id,
      v_sale_amount, v_fee_percent, v_fee_amount, v_net_amount,
      'pending', v_scheduled_date
    )
    on conflict (order_id, book_id) do nothing;
    if found then
      v_inserted_count := v_inserted_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'inserted_count', v_inserted_count
  );
end;
$$;

revoke execute on function public.create_settlements_for_order(bigint) from public;
revoke execute on function public.create_settlements_for_order(bigint) from authenticated;
grant execute on function public.create_settlements_for_order(bigint) to service_role;

commit;
