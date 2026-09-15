-- 상품 재고 탭 '점검 필요' 필터 (2026-09-15)
--
-- 배경: 주문이 들어온 뒤에야 위치 미지정 권이 대량으로 발견됨(피킹 지연).
-- 재고 화면에서 이상 항목을 미리 모아 보고 고칠 수 있게 한다.
--
-- 점검 대상 권 = 판매중(on_sale) + 출고 전 주문에 잡힌 권(reserved 이면서 pending/paid/preparing 주문의 미환불 품목).
--   · 이미 출고된 reserved 권(배송중·배송완료·구매확정, 정산 전)은 피킹이 끝났으므로 제외.
-- 항목:
--   missing_location      위치 미지정 (점검 대상 전체)
--   missing_serial        일련번호 없음 (점검 대상 전체)
--   missing_detail_photo  상세 사진 없음 (판매중만 — 스토어 노출 품질)
--   missing_price         판매가 없음 (판매중만 — 가격 없으면 노출 불가)
--   hidden_on_sale        판매중인데 비노출 (on_sale=공개 원칙, 7/19 확정)
--   missing_cover         판매중 재고가 있는데 상품 표지 없음 (상품 단위)
--
-- ⚠ admin_list_products_with_inventory 재정의 시 유지 필수:
--   locations 집계, 숫자 검색어의 일련번호 정확 일치 분기(재고 실사 이관 7/18), p_issue 필터·issues 집계.
-- 시그니처에 p_issue 가 추가되므로 기존 8인자 함수는 drop 후 재생성한다(오버로드 모호성 방지).
-- 기존 호출(8개 이름 인자)은 p_issue 기본값으로 그대로 동작한다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 권별 점검 플래그 (내부 헬퍼 — 관리자 RPC에서만 사용)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._admin_inventory_book_flags()
returns table (
  book_id bigint,
  product_id bigint,
  is_on_sale boolean,
  picking_pending boolean,
  missing_location boolean,
  missing_serial boolean,
  missing_detail_photo boolean,
  missing_price boolean,
  hidden_on_sale boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.product_id,
    b.status = 'on_sale',
    coalesce(pending.hit, false),
    nullif(btrim(b.location), '') is null,
    b.serial_number is null,
    b.status = 'on_sale' and coalesce(cardinality(b.inspection_image_urls), 0) = 0,
    b.status = 'on_sale' and coalesce(b.price, 0) <= 0,
    b.status = 'on_sale' and b.is_public is not true
  from public.books b
  left join lateral (
    select exists (
      select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.book_id = b.id
        and oi.refunded_at is null
        and o.status in ('pending', 'paid', 'preparing')
    ) as hit
  ) pending on b.status = 'reserved'
  where b.product_id is not null
    and (b.status = 'on_sale' or coalesce(pending.hit, false));
$$;

revoke all on function public._admin_inventory_book_flags() from public, anon, authenticated;
grant execute on function public._admin_inventory_book_flags() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 상품 목록 — p_issue 필터 + 상품별 issues 집계
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_list_products_with_inventory(text, text, text, text, text, integer, integer, text);

create function public.admin_list_products_with_inventory(
  p_search text default null,
  p_brand text default null,
  p_subject text default null,
  p_book_type text default null,
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_sort text default 'updated',
  p_issue text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_total integer;
  v_sort text;
  v_issue text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 알 수 없는 값은 기본(updated)으로 정규화
  v_sort := case when p_sort = 'created' then 'created' else 'updated' end;
  -- 알 수 없는 점검 항목은 필터 없음으로 취급
  v_issue := case
    when p_issue in ('any', 'missing_location', 'missing_serial', 'missing_detail_photo',
                     'missing_price', 'hidden_on_sale', 'missing_cover') then p_issue
    else null
  end;

  with iss as (
    select
      f.product_id,
      count(*) filter (where f.missing_location)::integer as missing_location,
      count(*) filter (where f.missing_location and f.picking_pending)::integer as missing_location_pending,
      count(*) filter (where f.missing_serial)::integer as missing_serial,
      count(*) filter (where f.missing_detail_photo)::integer as missing_detail_photo,
      count(*) filter (where f.missing_price)::integer as missing_price,
      count(*) filter (where f.hidden_on_sale)::integer as hidden_on_sale,
      count(*) filter (where f.is_on_sale)::integer as on_sale
    from public._admin_inventory_book_flags() f
    group by f.product_id
  )
  select count(*)::integer
  into v_total
  from public.products p
  left join iss on iss.product_id = p.id
  where (
    p_search is null or p_search = '' or
    p.title ilike '%' || p_search || '%' or
    coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
    coalesce(p.option, '') ilike '%' || p_search || '%' or
    (p_search ~ '^\d+$' and length(p_search) <= 9 and exists (
      select 1 from public.books bs
      where bs.product_id = p.id and bs.serial_number = p_search::integer
    ))
  )
  and (p_brand is null or p_brand = '' or p.brand = p_brand)
  and (p_subject is null or p_subject = '' or p.subject = p_subject)
  and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
  and (p_status is null or p_status = '' or p.status = p_status)
  and (
    v_issue is null
    or (v_issue = 'missing_location' and coalesce(iss.missing_location, 0) > 0)
    or (v_issue = 'missing_serial' and coalesce(iss.missing_serial, 0) > 0)
    or (v_issue = 'missing_detail_photo' and coalesce(iss.missing_detail_photo, 0) > 0)
    or (v_issue = 'missing_price' and coalesce(iss.missing_price, 0) > 0)
    or (v_issue = 'hidden_on_sale' and coalesce(iss.hidden_on_sale, 0) > 0)
    or (v_issue = 'missing_cover' and coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
    or (v_issue = 'any' and (
      coalesce(iss.missing_location, 0) + coalesce(iss.missing_serial, 0) + coalesce(iss.missing_detail_photo, 0)
        + coalesce(iss.missing_price, 0) + coalesce(iss.hidden_on_sale, 0) > 0
      or (coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
    ))
  );

  with iss as (
    select
      f.product_id,
      count(*) filter (where f.missing_location)::integer as missing_location,
      count(*) filter (where f.missing_location and f.picking_pending)::integer as missing_location_pending,
      count(*) filter (where f.missing_serial)::integer as missing_serial,
      count(*) filter (where f.missing_detail_photo)::integer as missing_detail_photo,
      count(*) filter (where f.missing_price)::integer as missing_price,
      count(*) filter (where f.hidden_on_sale)::integer as hidden_on_sale,
      count(*) filter (where f.is_on_sale)::integer as on_sale
    from public._admin_inventory_book_flags() f
    group by f.product_id
  )
  select coalesce(jsonb_agg(row_data
    order by
      (case when v_sort = 'created' then row_data->>'created_at' else row_data->>'updated_at' end) desc nulls last,
      (row_data->>'id')::bigint desc), '[]'::jsonb)
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
      'max_price', inv.max_price,
      'locations', coalesce(to_jsonb(inv.locations), '[]'::jsonb),
      'issues', jsonb_build_object(
        'missing_location', coalesce(iss.missing_location, 0),
        'missing_location_pending', coalesce(iss.missing_location_pending, 0),
        'missing_serial', coalesce(iss.missing_serial, 0),
        'missing_detail_photo', coalesce(iss.missing_detail_photo, 0),
        'missing_price', coalesce(iss.missing_price, 0),
        'hidden_on_sale', coalesce(iss.hidden_on_sale, 0),
        'missing_cover', coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null
      )
    ) as row_data
    from public.products p
    left join iss on iss.product_id = p.id
    left join lateral (
      select
        count(*) filter (where b.status = 'on_sale') as on_sale_count,
        count(*) filter (where b.status = 'on_sale' and b.is_public = true) as public_count,
        count(*) as total_count,
        min(b.price) filter (where b.status = 'on_sale') as min_price,
        max(b.price) filter (where b.status = 'on_sale') as max_price,
        array_agg(distinct b.location order by b.location)
          filter (where b.status = 'on_sale' and b.location is not null) as locations
      from public.books b
      where b.product_id = p.id
    ) inv on true
    where (
      p_search is null or p_search = '' or
      p.title ilike '%' || p_search || '%' or
      coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
      coalesce(p.option, '') ilike '%' || p_search || '%' or
      (p_search ~ '^\d+$' and length(p_search) <= 9 and exists (
        select 1 from public.books bs
        where bs.product_id = p.id and bs.serial_number = p_search::integer
      ))
    )
    and (p_brand is null or p_brand = '' or p.brand = p_brand)
    and (p_subject is null or p_subject = '' or p.subject = p_subject)
    and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
    and (p_status is null or p_status = '' or p.status = p_status)
    and (
      v_issue is null
      or (v_issue = 'missing_location' and coalesce(iss.missing_location, 0) > 0)
      or (v_issue = 'missing_serial' and coalesce(iss.missing_serial, 0) > 0)
      or (v_issue = 'missing_detail_photo' and coalesce(iss.missing_detail_photo, 0) > 0)
      or (v_issue = 'missing_price' and coalesce(iss.missing_price, 0) > 0)
      or (v_issue = 'hidden_on_sale' and coalesce(iss.hidden_on_sale, 0) > 0)
      or (v_issue = 'missing_cover' and coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
      or (v_issue = 'any' and (
        coalesce(iss.missing_location, 0) + coalesce(iss.missing_serial, 0) + coalesce(iss.missing_detail_photo, 0)
          + coalesce(iss.missing_price, 0) + coalesce(iss.hidden_on_sale, 0) > 0
        or (coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
      ))
    )
    order by
      (case when v_sort = 'created' then p.created_at else p.updated_at end) desc nulls last,
      p.id desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

revoke all on function public.admin_list_products_with_inventory(text, text, text, text, text, integer, integer, text, text) from public, anon;
grant execute on function public.admin_list_products_with_inventory(text, text, text, text, text, integer, integer, text, text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 점검 요약 — 항목별 권수·상품수 (재고 탭 상단 칩)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_get_inventory_issue_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  with flags as (
    select * from public._admin_inventory_book_flags()
  ),
  covers as (
    select p.id
    from public.products p
    where nullif(btrim(p.cover_image_url), '') is null
      and exists (select 1 from public.books b where b.product_id = p.id and b.status = 'on_sale')
  ),
  any_products as (
    select product_id from flags
    where missing_location or missing_serial or missing_detail_photo or missing_price or hidden_on_sale
    union
    select id from covers
  )
  select jsonb_build_object(
    'missing_location', jsonb_build_object(
      'books', count(*) filter (where missing_location),
      'products', count(distinct product_id) filter (where missing_location),
      'pending_books', count(*) filter (where missing_location and picking_pending)
    ),
    'missing_serial', jsonb_build_object(
      'books', count(*) filter (where missing_serial),
      'products', count(distinct product_id) filter (where missing_serial),
      'pending_books', count(*) filter (where missing_serial and picking_pending)
    ),
    'missing_detail_photo', jsonb_build_object(
      'books', count(*) filter (where missing_detail_photo),
      'products', count(distinct product_id) filter (where missing_detail_photo)
    ),
    'missing_price', jsonb_build_object(
      'books', count(*) filter (where missing_price),
      'products', count(distinct product_id) filter (where missing_price)
    ),
    'hidden_on_sale', jsonb_build_object(
      'books', count(*) filter (where hidden_on_sale),
      'products', count(distinct product_id) filter (where hidden_on_sale)
    ),
    'missing_cover', jsonb_build_object(
      'products', (select count(*) from covers)
    ),
    'any', jsonb_build_object(
      'products', (select count(*) from any_products)
    )
  )
  into v_result
  from flags;

  return v_result;
end;
$$;

revoke all on function public.admin_get_inventory_issue_summary() from public, anon;
grant execute on function public.admin_get_inventory_issue_summary() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 상품 상세(권별 현황) — 상세 사진 수·출고 전 주문 여부 추가
--    기존 반환 필드(위치·일련번호 포함)는 그대로 유지
-- ─────────────────────────────────────────────────────────────────────────────
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
    'option', b.option,
    'condition_grade', coalesce(b.condition_grade, 'S'),
    'price', b.price,
    'status', b.status,
    'is_public', b.is_public,
    'cover_image_url', b.cover_image_url,
    'created_at', b.created_at,
    'serial_number', b.serial_number,
    'location', b.location,
    'detail_photo_count', coalesce(cardinality(b.inspection_image_urls), 0),
    'picking_pending', b.status = 'reserved' and exists (
      select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.book_id = b.id
        and oi.refunded_at is null
        and o.status in ('pending', 'paid', 'preparing')
    )
  ) order by s.seller_name nulls last, b.option nulls last, b.id), '[]'::jsonb)
  into v_books
  from public.books b
  left join public.shipments s on s.id = b.shipment_id
  where b.product_id = p_product_id;

  return jsonb_build_object('product', v_product, 'books', v_books);
end;
$$;

commit;
