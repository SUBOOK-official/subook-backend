-- 어드민 목록 RPC 3종에 페이지네이션 메타(total_count)를 추가.
--
-- 기존: list_admin_orders / admin_list_coupons / admin_list_products_with_inventory
--   → jsonb 배열만 반환. 클라이언트가 전체 건수를 모르므로 페이지네이션 불가.
-- 변경: → { items: jsonb[], total_count: integer } 형태로 반환.
--
-- 호출자는 admin-web 3개 페이지뿐이며 같은 PR에서 함께 업데이트한다.

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

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;


create or replace function public.admin_list_coupons(
  p_search text default null,
  p_only_active boolean default false,
  p_limit integer default 100,
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
  from public.coupons c
  where
    (p_search is null or p_search = ''
      or c.title ilike '%' || p_search || '%'
      or coalesce(c.code, '') ilike '%' || p_search || '%')
    and (p_only_active = false or c.is_active = true);

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select to_jsonb(c.*) as row_data
    from public.coupons c
    where
      (p_search is null or p_search = ''
        or c.title ilike '%' || p_search || '%'
        or coalesce(c.code, '') ilike '%' || p_search || '%')
      and (p_only_active = false or c.is_active = true)
    order by c.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;


create or replace function public.admin_list_products_with_inventory(
  p_search text default null,
  p_brand text default null,
  p_subject text default null,
  p_book_type text default null,
  p_status text default null,
  p_limit integer default 100,
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
  from public.products p
  where (
    p_search is null or p_search = '' or
    p.title ilike '%' || p_search || '%' or
    coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
    coalesce(p.option, '') ilike '%' || p_search || '%'
  )
  and (p_brand is null or p_brand = '' or p.brand = p_brand)
  and (p_subject is null or p_subject = '' or p.subject = p_subject)
  and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
  and (p_status is null or p_status = '' or p.status = p_status);

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', p.id,
      'group_key', p.group_key,
      'title', p.title,
      'option', p.option,
      'subject', p.subject,
      'brand', p.brand,
      'book_type', p.book_type,
      'published_year', p.published_year,
      'instructor_name', p.instructor_name,
      'cover_image_url', p.cover_image_url,
      'status', p.status,
      'created_at', p.created_at,
      'updated_at', p.updated_at,
      'inventory_count', coalesce(inv.on_sale_count, 0),
      'public_count', coalesce(inv.public_count, 0),
      'total_book_count', coalesce(inv.total_count, 0),
      'min_price', inv.min_price,
      'max_price', inv.max_price
    ) as row_data
    from public.products p
    left join lateral (
      select
        count(*) filter (where b.status = 'on_sale') as on_sale_count,
        count(*) filter (where b.status = 'on_sale' and b.is_public = true) as public_count,
        count(*) as total_count,
        min(b.price) filter (where b.status = 'on_sale') as min_price,
        max(b.price) filter (where b.status = 'on_sale') as max_price
      from public.books b
      where b.product_id = p.id
    ) inv on true
    where (
      p_search is null or p_search = '' or
      p.title ilike '%' || p_search || '%' or
      coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
      coalesce(p.option, '') ilike '%' || p_search || '%'
    )
    and (p_brand is null or p_brand = '' or p.brand = p_brand)
    and (p_subject is null or p_subject = '' or p.subject = p_subject)
    and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
    and (p_status is null or p_status = '' or p.status = p_status)
    order by p.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;
