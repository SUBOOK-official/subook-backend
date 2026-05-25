-- 구매자 환불 신청이 어드민 페이지에 보이지 않던 버그 fix.
--
-- 기존: request_member_refund RPC가 orders.refund_requested_at /
--       refund_request_reason에 잘 기록하지만, list_admin_orders RPC가 이 필드들을
--       반환하지 않아 어드민 UI에서 환불 신청을 인지할 방법이 없었음.
--
-- 변경:
--   1. list_admin_orders에 refund_requested_at, refund_request_reason,
--      refunded_at, refund_reason 필드 추가
--   2. get_admin_order_summary에 refund_pending_count 추가
--      (= 환불 신청 접수됐는데 아직 처리 안 된 건수)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) list_admin_orders: 환불 메타 필드 4개 노출
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_items jsonb;
  v_total integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
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
    and (p_to_date is null or o.created_at < p_to_date + interval '1 day');

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
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
      -- ⚠ 환불 메타 4종 — 어드민이 환불 신청 큐를 보고 처리할 수 있도록 노출
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
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
    -- 환불 신청 접수된 주문은 위로 — 어드민이 즉시 확인하도록
    order by
      (case when o.refund_requested_at is not null and o.status <> 'refunded' then 0 else 1 end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) get_admin_order_summary: refund_pending_count 추가
-- ─────────────────────────────────────────────────────────────────────────────
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
    'cancelled_count', (select count(*) from public.orders where status = 'cancelled'),
    -- 환불 신청 접수됐지만 아직 처리(refunded) 안 된 큐
    'refund_pending_count', (
      select count(*) from public.orders
      where refund_requested_at is not null
        and status <> 'refunded'
    )
  );
end;
$$;

commit;
