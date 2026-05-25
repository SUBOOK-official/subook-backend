-- 환불 처리 후 책이 storefront에 다시 노출 안 되던 버그 fix.
--
-- 원인: books_enforce_public_storefront_rules 트리거가
--       status != 'on_sale'이면 is_public을 자동으로 false로 set함.
--       paid 전이 시 books가 reserved가 되며 is_public=false가 강제됐는데,
--       환불 시 status는 on_sale로 복원했지만 is_public은 false 그대로 남아
--       storefront RPC(b.status='on_sale' AND b.is_public=true)에 안 잡힘.
--
-- 변경: admin_refund_order / admin_update_order_status cancelled 분기에서
--       books를 on_sale로 복원할 때 is_public=true도 같이 set.
--       (결제까지 진행된 책 = 한때 storefront에 노출됐던 책 = 다시 노출돼야 함.
--        product_id/title/price/condition_grade 검사는 트리거가 자동으로 함.)
--
-- 추가: 백필 — 현재 status='on_sale'인데 is_public=false인 책 중
--       active order 안 묶인 것들을 is_public=true로 복원.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) admin_update_order_status: cancelled 시 is_public=true 같이 복원
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

  if p_status = 'paid' then
    -- paid 전이: books → reserved (트리거가 is_public=false 자동 set)
    update public.books
    set status = 'reserved'
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'on_sale';
  elsif p_status = 'cancelled' then
    -- cancelled 복원: status=on_sale + is_public=true 같이 set.
    -- 트리거가 product_id/title/price/condition_grade 검증하지만, 결제까지 갔던
    -- 책은 모두 만족하므로 통과.
    update public.books
    set status = 'on_sale', is_public = true
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'reserved';
  end if;

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
-- 2) admin_refund_order: is_public=true 같이 복원
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

  -- ⚠ 핵심 변경: reserved 책을 on_sale + is_public=true로 같이 복원
  -- (settled 책은 이미 정산 처리됐으므로 storefront 복원하지 않음)
  update public.books
  set status = 'on_sale', is_public = true
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
-- 3) Backfill: 이미 환불 처리됐는데 is_public=false로 남은 책들 복원
--    조건: status='on_sale' AND is_public=false AND active order에 안 묶인 책
--    AND product_id/title/price/condition_grade 모두 존재
--    (한때 storefront에 노출됐던 책만 — paid 이력 있어야 함)
-- ─────────────────────────────────────────────────────────────────────────────
update public.books b
set is_public = true
where b.status = 'on_sale'
  and b.is_public = false
  and b.product_id is not null
  and b.title is not null
  and b.price is not null
  and b.condition_grade is not null
  and not exists (
    select 1
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = b.id
      and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
  )
  and exists (
    -- 한때 결제까지 갔던 이력이 있는 책만 (refunded/cancelled 이력)
    select 1
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = b.id
      and o.status in ('refunded', 'cancelled')
  );

commit;
