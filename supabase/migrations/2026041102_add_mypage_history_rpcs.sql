-- 사용자 수거 요청 내역 조회
create or replace function public.get_my_pickup_requests(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', pr.id,
      'request_number', pr.request_number,
      'status', pr.status,
      'item_count', pr.item_count,
      'tracking_number', pr.tracking_number,
      'tracking_carrier', pr.tracking_carrier,
      'created_at', pr.created_at,
      'updated_at', pr.updated_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', pi.id,
          'title', pi.title,
          'subject', pi.subject,
          'brand', pi.brand,
          'book_type', pi.book_type,
          'original_price', pi.original_price,
          'condition_memo', pi.condition_memo,
          'is_manual_entry', pi.is_manual_entry,
          'cover_photo_url', pi.cover_photo_url
        ) order by pi.id)
        from public.pickup_items pi
        where pi.pickup_request_id = pr.id
      ), '[]'::jsonb)
    ) as row_data
    from public.pickup_requests pr
    where pr.user_id = v_user_id
    order by pr.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

-- 사용자 주문 내역 조회
create or replace function public.get_my_orders(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
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
      'discount_amount', o.discount_amount,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
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
    where o.user_id = v_user_id
    order by o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;
