-- 어드민 상품 마스터 페이지 (/admin/products) 용 RPC.
-- 식스샵 스타일: products 단위 그리드 + 그 product의 books 인스턴스 상세.

-- 1) 상품 마스터 목록 (재고/가격/상태 집계 포함)
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
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
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
      'total_book_count', coalesce(inv.total_count, 0),
      'min_price', inv.min_price,
      'max_price', inv.max_price
    ) as row_data
    from public.products p
    left join lateral (
      select
        count(*) filter (where b.status = 'on_sale' and b.is_public = true) as on_sale_count,
        count(*) as total_count,
        min(b.price) filter (where b.status = 'on_sale' and b.is_public = true) as min_price,
        max(b.price) filter (where b.status = 'on_sale' and b.is_public = true) as max_price
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

  return v_result;
end;
$$;

-- 2) 상품 단위 통계 (탭 카운트용)
create or replace function public.admin_get_products_summary()
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
    'total', (select count(*) from public.products),
    'selling', (select count(*) from public.products where status = 'selling'),
    'sold_out', (select count(*) from public.products where status = 'sold_out'),
    'hidden', (select count(*) from public.products where status = 'hidden')
  );
end;
$$;

-- 3) 단일 product 상세 + 그 product의 books 인스턴스 목록 (상세 모달용)
create or replace function public.admin_get_product_inventory(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product jsonb;
  v_books jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select to_jsonb(p) into v_product from public.products p where p.id = p_product_id;
  if v_product is null then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'shipment_id', b.shipment_id,
    'seller_name', s.seller_name,
    'seller_phone', s.seller_phone,
    'condition_grade', b.condition_grade,
    'price', b.price,
    'status', b.status,
    'is_public', b.is_public,
    'cover_image_url', b.cover_image_url,
    'created_at', b.created_at
  ) order by b.created_at desc), '[]'::jsonb)
  into v_books
  from public.books b
  left join public.shipments s on s.id = b.shipment_id
  where b.product_id = p_product_id;

  return jsonb_build_object(
    'product', v_product,
    'books', v_books
  );
end;
$$;

-- 4) 상품 상태 토글 (selling / hidden / sold_out)
create or replace function public.admin_set_product_status(p_product_id bigint, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_status not in ('selling', 'sold_out', 'hidden') then
    raise exception '올바르지 않은 상태입니다.';
  end if;

  update public.products
  set status = p_status, updated_at = now()
  where id = p_product_id;

  if not found then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  return jsonb_build_object('success', true, 'product_id', p_product_id, 'status', p_status);
end;
$$;

-- 5) 책(인스턴스) 노출 토글 — 어드민이 모달에서 사용
create or replace function public.admin_set_book_visibility(p_book_id bigint, p_is_public boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product_id bigint;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  update public.books
  set is_public = p_is_public
  where id = p_book_id
  returning product_id into v_product_id;

  if v_product_id is null then
    raise exception '책을 찾을 수 없습니다.';
  end if;

  -- 이 product의 재고/판매 상태 갱신 (기존 trigger와 별개로 명시적 호출)
  perform public.refresh_storefront_product_status(v_product_id);

  return jsonb_build_object('success', true, 'book_id', p_book_id, 'is_public', p_is_public);
end;
$$;

grant execute on function public.admin_list_products_with_inventory(text, text, text, text, text, integer, integer) to authenticated;
grant execute on function public.admin_get_products_summary() to authenticated;
grant execute on function public.admin_get_product_inventory(bigint) to authenticated;
grant execute on function public.admin_set_product_status(bigint, text) to authenticated;
grant execute on function public.admin_set_book_visibility(bigint, boolean) to authenticated;
