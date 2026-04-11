-- 구매자 구매확정 RPC (delivered 상태에서만 가능)
create or replace function public.confirm_member_purchase(p_order_id bigint)
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

  if v_order.status != 'delivered' then
    raise exception '배송완료 상태에서만 구매확정이 가능합니다. (현재: %)', v_order.status;
  end if;

  if v_order.confirmed_at is not null then
    raise exception '이미 구매확정된 주문입니다.';
  end if;

  update public.orders
  set
    status = 'confirmed',
    confirmed_at = now(),
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

-- 구매자 주문 취소 RPC (pending/paid 상태에서만 가능)
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

  if v_order.status not in ('pending', 'paid') then
    raise exception '입금대기 또는 결제완료 상태에서만 취소가 가능합니다. (현재: %)', v_order.status;
  end if;

  -- 주문 취소 처리
  update public.orders
  set
    status = 'cancelled',
    payment_status = case when v_order.payment_status = 'paid' then 'refunded' else payment_status end,
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  -- 상품 재고 복구: 상품을 다시 판매 가능 상태로
  update public.products
  set status = 'on_sale', updated_at = now()
  where id in (
    select product_id from public.order_items where order_id = p_order_id and product_id is not null
  );

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

-- 배송완료 D+7 자동 구매확정 (Cron에서 호출, service_role로 실행)
create or replace function public.auto_confirm_delivered_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_confirmed_count integer;
begin
  update public.orders
  set
    status = 'confirmed',
    confirmed_at = now(),
    updated_at = now()
  where
    status = 'delivered'
    and confirmed_at is null
    and auto_confirm_at is not null
    and auto_confirm_at <= now();

  get diagnostics v_confirmed_count = row_count;

  return jsonb_build_object(
    'success', true,
    'confirmed_count', v_confirmed_count,
    'executed_at', now()
  );
end;
$$;

-- admin_update_order_status에 배송완료 시 auto_confirm_at 자동 설정 추가
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
  if p_status = 'shipping' and v_order.status not in ('paid') then
    raise exception 'Cannot mark as shipping from status: %', v_order.status;
  end if;
  if p_status = 'delivered' and v_order.status not in ('shipping') then
    raise exception 'Cannot mark as delivered from status: %', v_order.status;
  end if;
  if p_status = 'cancelled' and v_order.status not in ('pending', 'paid') then
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
