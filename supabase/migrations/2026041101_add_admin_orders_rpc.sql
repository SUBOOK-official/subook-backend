-- 관리자 주문 목록 조회
create or replace function public.list_admin_orders(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'shipping_recipient_name', o.shipping_recipient_name,
      'shipping_recipient_phone', o.shipping_recipient_phone,
      'shipping_postal_code', o.shipping_postal_code,
      'shipping_address_line1', o.shipping_address_line1,
      'shipping_address_line2', o.shipping_address_line2,
      'shipping_memo', o.shipping_memo,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'buyer_email', p.email,
      'buyer_name', p.name,
      'buyer_phone', p.phone,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price
        ) order by oi.id)
        from public.order_items oi
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    left join public.member_profiles p on p.user_id = o.user_id
    where
      (p_search is null or p_search = '' or
        o.order_number ilike '%' || p_search || '%' or
        p.name ilike '%' || p_search || '%' or
        p.email ilike '%' || p_search || '%' or
        p.phone ilike '%' || p_search || '%' or
        o.shipping_recipient_name ilike '%' || p_search || '%')
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= p_from_date)
      and (p_to_date is null or o.created_at < p_to_date + interval '1 day')
    order by o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

-- 관리자 주문 상태 변경
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
    updated_at = now()
  where id = p_order_id;

  return jsonb_build_object('success', true, 'order_id', p_order_id, 'new_status', p_status);
end;
$$;

-- 관리자 주문 요약 통계
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
    'shipping_count', (select count(*) from public.orders where status = 'shipping'),
    'delivered_count', (select count(*) from public.orders where status = 'delivered'),
    'confirmed_count', (select count(*) from public.orders where status = 'confirmed'),
    'cancelled_count', (select count(*) from public.orders where status = 'cancelled')
  );
end;
$$;
