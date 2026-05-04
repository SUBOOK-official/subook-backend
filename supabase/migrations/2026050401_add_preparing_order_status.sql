-- 'preparing' (상품 준비 중) 단계 추가
-- 워크플로우:
--   pending(입금대기) → paid(결제완료) → preparing(상품 준비 중, 어드민 수동 전환)
--   → shipping(배송중, 운송장 등록) → delivered(배송완료) → confirmed(구매확정)
--
-- 추가 규칙:
-- - 사용자는 배송 전(pending/paid/preparing) 상태에서 주문 취소 가능
-- - 어드민은 paid → shipping 직행도 호환을 위해 허용 (preparing 단계를 건너뛰는 운영 케이스)

-- 1) orders.status CHECK constraint에 'preparing' 추가
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('pending', 'paid', 'preparing', 'shipping', 'delivered', 'confirmed', 'cancelled', 'refunded'));

-- 2) cancel_member_order RPC: preparing 단계도 사용자 취소 허용
create or replace function public.cancel_member_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_order record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_order from public.orders where id = p_order_id and user_id = v_user_id;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status not in ('pending', 'paid', 'preparing') then
    raise exception '입금대기 / 결제완료 / 상품 준비 중 상태에서만 취소가 가능합니다. (현재: %)', v_order.status;
  end if;

  update public.orders
  set
    status = 'cancelled',
    payment_status = case when v_order.payment_status = 'paid' then 'refunded' else payment_status end,
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  -- 상품 재고 복구
  update public.products
  set status = 'on_sale', updated_at = now()
  where id in (
    select product_id from public.order_items where order_id = p_order_id and product_id is not null
  );

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

-- 3) admin_update_order_status RPC: preparing 전이 규칙 추가
--    - paid → preparing 추가
--    - shipping은 paid 또는 preparing에서 모두 진입 가능 (preparing 단계 건너뛰기 호환)
--    - cancelled는 preparing 에서도 가능
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

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found';
  end if;

  -- 상태 전이 검증
  if p_status = 'paid' and v_order.status not in ('pending') then
    raise exception 'Cannot mark as paid from status: %', v_order.status;
  end if;
  if p_status = 'preparing' and v_order.status not in ('paid') then
    raise exception 'Cannot mark as preparing from status: %', v_order.status;
  end if;
  if p_status = 'shipping' and v_order.status not in ('paid', 'preparing') then
    raise exception 'Cannot mark as shipping from status: %', v_order.status;
  end if;
  if p_status = 'delivered' and v_order.status not in ('shipping') then
    raise exception 'Cannot mark as delivered from status: %', v_order.status;
  end if;
  if p_status = 'cancelled' and v_order.status not in ('pending', 'paid', 'preparing') then
    raise exception 'Cannot cancel from status: %', v_order.status;
  end if;

  update public.orders
  set
    status = p_status,
    payment_status = case when p_status = 'paid' then 'paid' when p_status = 'cancelled' then 'refunded' else payment_status end,
    tracking_number = coalesce(p_tracking_number, tracking_number),
    tracking_carrier = coalesce(p_tracking_carrier, tracking_carrier),
    confirmed_at = case when p_status = 'confirmed' then now() else confirmed_at end,
    auto_confirm_at = case when p_status = 'delivered' then now() + interval '7 days' else auto_confirm_at end,
    updated_at = now()
  where id = p_order_id;

  return jsonb_build_object('success', true, 'order_id', p_order_id, 'new_status', p_status);
end;
$$;

-- 4) get_admin_order_summary: preparing_count 추가
create or replace function public.get_admin_order_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  return jsonb_build_object(
    'total_count', (select count(*) from public.orders),
    'pending_count', (select count(*) from public.orders where status = 'pending'),
    'paid_count', (select count(*) from public.orders where status = 'paid'),
    'preparing_count', (select count(*) from public.orders where status = 'preparing'),
    'shipping_count', (select count(*) from public.orders where status = 'shipping'),
    'delivered_count', (select count(*) from public.orders where status = 'delivered'),
    'confirmed_count', (select count(*) from public.orders where status = 'confirmed'),
    'cancelled_count', (select count(*) from public.orders where status = 'cancelled')
  );
end;
$$;
