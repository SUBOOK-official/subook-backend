-- 결제완료된 책이 storefront에 계속 노출되던 버그 fix.
--
-- 기존 흐름:
--   order pending → on_sale (정상)
--   order paid    → on_sale (버그: storefront에 계속 노출)
--   order confirmed → settlement trigger → settled
--
-- 변경 후:
--   order pending → on_sale (그대로, P0 #4 정책: pending끼리는 같은 책 공존 허용)
--   order paid (admin_confirm_payment) → reserved (storefront 비노출)
--   order cancelled (paid에서) → on_sale 복원
--   order refunded → on_sale 복원 (단 이미 settled인 책은 그대로 — 정산 환수는 별도)
--   order confirmed → settlement trigger → settled
--
-- storefront RPC들은 모두 `b.status = 'on_sale'` 필터를 거므로 reserved 책은 자동 비노출.
-- RPC 정의 변경은 불필요.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) books_status_check에 'reserved' 추가
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.books drop constraint if exists books_status_check;
alter table public.books add constraint books_status_check
  check (status in ('on_sale', 'reserved', 'settled', 'discarded'));
-- 'discarded'는 2026051304_add_discard_grade에서 추가됨 — 같이 명시 (회복 시 누락 방지).

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) admin_confirm_payment: paid 전이 후 해당 order_items의 books를 reserved로 set
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

  -- 동일 책에 이미 paid 이상인 active order가 있으면 reject
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

  -- ⚠ 핵심 변경: 결제완료된 books를 reserved로 set → storefront에서 즉시 비노출.
  update public.books
  set status = 'reserved'
  where id in (
    select oi.book_id from public.order_items oi where oi.order_id = p_order_id
  )
  and status = 'on_sale';

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'new_status', 'paid',
    'verified_amount', v_order.total_amount
  );
end;
$$;

grant execute on function public.admin_confirm_payment(bigint, integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) admin_update_order_status: cancelled 전이 시 reserved → on_sale 복원,
--    paid 전이 시 (호환 경로) reserved set
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

  if p_status not in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed', 'cancelled') then
    raise exception 'Invalid status: % (허용: paid/preparing/shipping/delivered/confirmed/cancelled)', p_status;
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found';
  end if;

  if p_status = 'paid' then
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

  -- ⚠ books status 동기화:
  --   paid (호환 경로) → reserved
  --   cancelled (paid 이상에서) → on_sale 복원
  if p_status = 'paid' then
    update public.books
    set status = 'reserved'
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'on_sale';
  elsif p_status = 'cancelled' then
    update public.books
    set status = 'on_sale'
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'reserved';
  end if;

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
-- 4) admin_refund_order: 환불 시 reserved → on_sale 복원
--    단 이미 settled인 책은 그대로 (정산 환수는 별도 흐름).
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
  v_restored_books integer := 0;
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

  update public.orders
  set
    status = 'refunded',
    payment_status = case when payment_status = 'paid' then 'refunded' else payment_status end,
    refunded_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where id = p_order_id;

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

  -- 쿠폰 복구
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

  -- ⚠ 핵심 변경: reserved인 책만 on_sale로 복원. settled는 그대로 (정산 환수는 별도).
  update public.books
  set status = 'on_sale'
  where id in (
    select oi.book_id from public.order_items oi where oi.order_id = p_order_id
  )
  and status = 'reserved';
  get diagnostics v_restored_books = row_count;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'cancelled_settlements', v_cancelled_settlements,
    'recovery_required_settlements', v_recovery_settlements,
    'restored_books', v_restored_books,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

grant execute on function public.admin_refund_order(bigint, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) 데이터 backfill: 현재 active order(paid/preparing/shipping/delivered)에 묶인
--    on_sale 책들을 reserved로 일괄 변환. 이번 fix 적용 시점에 이미 결제완료된
--    주문도 즉시 storefront에서 비노출되도록.
-- ─────────────────────────────────────────────────────────────────────────────
update public.books b
set status = 'reserved'
where b.status = 'on_sale'
  and exists (
    select 1
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = b.id
      and o.status in ('paid', 'preparing', 'shipping', 'delivered')
  );

commit;
