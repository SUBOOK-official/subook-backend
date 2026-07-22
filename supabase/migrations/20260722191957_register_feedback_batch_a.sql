-- 7/22 운영자 피드백 배치 A — 운영 블로커 수리 (2026-07-23)
--
-- 1) admin_search_products_for_register: 정렬을 제목 오름차순 → 연도 내림차순 우선으로.
--    증상(운영자): "서바이벌"로 검색하면 2026년판이 안 나오고 2024·2025만 뜸.
--    원인(실측): 매칭 74건을 title asc로 정렬해 상한에서 자르니 "2024…","2025…" 제목이
--    상위를 선점 — 2026년판 첫 순위가 27위라 전부 잘림. published_year desc nulls last
--    우선으로 바꾸면 최신판이 최상단 (프로덕션 실데이터로 검증, 789/813 상품이 연도 보유).
--    (CREATE OR REPLACE — jsonb 반환·시그니처 동일, 비파괴)
--
-- 2) admin_list_products_with_inventory: p_sort 파라미터 추가 (updated|created).
--    증상(운영자): 기존 상품에 재고를 추가하면 등록순 정렬에서 과거 위치에 묻혀 못 찾음.
--    products.updated_at은 books 변경 행 트리거(refresh_storefront_product_status)가
--    항상 갱신하므로 정렬 분기만 추가. 파라미터 추가 = 시그니처 변경이므로 구버전을
--    drop 후 재생성 (남겨두면 PostgREST 오버로드 모호성 PGRST203 발생). default가
--    있어 구버전 프론트 호출(p_sort 미전달)도 그대로 동작.
--
-- 3) admin_bulk_set_products_visibility 신규: 상품 단위 일괄 노출/숨김.
--    기존 admin_bulk_update_product_status는 파생 표시값 products.status만 UPDATE —
--    스토어 목록은 books.is_public로 필터하므로 실제 노출이 안 바뀌고, 다음 books
--    변경 때 트리거가 status를 원복하는 버그. 프론트에서 사용 중단하고 이 함수로 교체.
--    books.is_public을 직접 플립하면 행 트리거가 products.status·updated_at을 재계산.
--    공개 필터는 books_enforce_public_storefront_rules(BEFORE 트리거)의 필수 필드
--    조건을 그대로 미러링 — 한 권이라도 조건 미달로 예외가 나면 전체 롤백되므로
--    조건 충족 권만 플립하고, 노출된 재고가 없는 상품은 skipped로 보고한다.

begin;

-- ── 1) 등록 검색: 최신 연도 우선 정렬 ─────────────────────────────────────────

create or replace function public.admin_search_products_for_register(
  p_search text default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_search text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_search := nullif(btrim(coalesce(p_search, '')), '');
  if v_search is null then
    return '[]'::jsonb;
  end if;

  select coalesce(
    jsonb_agg(row_data
      order by (row_data->>'published_year')::int desc nulls last, row_data->>'title'),
    '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', p.id,
      'title', p.title,
      'option', p.option,
      'subject', p.subject,
      'brand', p.brand,
      'book_type', p.book_type,
      'published_year', p.published_year,
      'instructor_name', p.instructor_name,
      'cover_image_url', p.cover_image_url,
      -- 기존 상세사진 대표값 — 상세사진이 있는 첫 책의 세트 (책 종류 단위 규칙)
      'detail_image_urls', coalesce(
        (select b3.inspection_image_urls
         from public.books b3
         where b3.product_id = p.id
           and array_length(b3.inspection_image_urls, 1) > 0
         order by b3.id
         limit 1),
        '{}'::text[]
      ),
      'representative_original_price', agg.rep_original,
      'representative_grade', coalesce(
        (select mode() within group (order by b2.condition_grade)
         from public.books b2 where b2.product_id = p.id and b2.status = 'on_sale'),
        'S'
      ),
      'inventory_count', coalesce(agg.stock_total, 0),
      'options', coalesce(agg.options, '[]'::jsonb)
    ) as row_data
    from public.products p
    left join lateral (
      select
        sum(g.cnt) as stock_total,
        max(g.max_original) as rep_original,
        jsonb_agg(jsonb_build_object(
          'option', g.option,
          'stock_count', g.cnt,
          'price', g.min_price,
          'original_price', g.max_original
        ) order by g.option nulls first) as options
      from (
        select b.option, count(*) as cnt, min(b.price) as min_price, max(b.original_price) as max_original
        from public.books b
        where b.product_id = p.id and b.status = 'on_sale'
        group by b.option
      ) g
    ) agg on true
    where (
      p.title ilike '%' || v_search || '%'
      or coalesce(p.instructor_name, '') ilike '%' || v_search || '%'
      or coalesce(p.option, '') ilike '%' || v_search || '%'
    )
    order by p.published_year desc nulls last, p.title
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.admin_search_products_for_register(text, integer) to authenticated;

-- ── 2) 재고 목록: p_sort (updated = 최근 수정순 기본 | created = 최신 등록순) ──

drop function if exists public.admin_list_products_with_inventory(text, text, text, text, text, integer, integer);

create or replace function public.admin_list_products_with_inventory(
  p_search text default null,
  p_brand text default null,
  p_subject text default null,
  p_book_type text default null,
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_sort text default 'updated'
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
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 알 수 없는 값은 기본(updated)으로 정규화
  v_sort := case when p_sort = 'created' then 'created' else 'updated' end;

  select count(*)::integer
  into v_total
  from public.products p
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
  and (p_status is null or p_status = '' or p.status = p_status);

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
      'locations', coalesce(to_jsonb(inv.locations), '[]'::jsonb)
    ) as row_data
    from public.products p
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
    order by
      (case when v_sort = 'created' then p.created_at else p.updated_at end) desc nulls last,
      p.id desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

grant execute on function public.admin_list_products_with_inventory(text, text, text, text, text, integer, integer, text) to authenticated;

-- ── 3) 상품 단위 일괄 노출/숨김 ───────────────────────────────────────────────

create or replace function public.admin_bulk_set_products_visibility(
  p_product_ids bigint[],
  p_is_public boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
  v_skipped bigint[] := '{}';
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_product_ids is null or coalesce(array_length(p_product_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'updated_books', 0, 'skipped_product_ids', '[]'::jsonb);
  end if;

  if p_is_public then
    -- books_enforce_public_storefront_rules(BEFORE 트리거)의 필수 필드 조건 미러 —
    -- 조건 미달 권에 is_public=true를 시도하면 예외로 전체 롤백되므로 사전 필터.
    update public.books b
    set is_public = true
    where b.product_id = any(p_product_ids)
      and b.is_public = false
      and b.status = 'on_sale'
      and nullif(btrim(coalesce(b.title, '')), '') is not null
      and nullif(btrim(coalesce(b.subject, '')), '') is not null
      and nullif(btrim(coalesce(b.brand, '')), '') is not null
      and nullif(btrim(coalesce(b.book_type, '')), '') is not null
      and b.published_year is not null
      and b.original_price is not null
      and b.price is not null
      and nullif(btrim(coalesce(b.cover_image_url, '')), '') is not null
      and nullif(btrim(coalesce(b.condition_grade, '')), '') is not null
      and b.writing_percentage is not null
      and b.has_damage is not null
      and b.inspected_at is not null;
    get diagnostics v_updated = row_count;

    -- 처리 후에도 노출 재고가 0인 상품 = 운영자에게 알려야 할 실패 케이스
    select coalesce(array_agg(pid), '{}')
    into v_skipped
    from unnest(p_product_ids) as pid
    where not exists (
      select 1 from public.books b
      where b.product_id = pid and b.status = 'on_sale' and b.is_public = true
    );
  else
    update public.books b
    set is_public = false
    where b.product_id = any(p_product_ids)
      and b.is_public = true;
    get diagnostics v_updated = row_count;
  end if;

  -- products.status·updated_at은 books 행 트리거(refresh_storefront_product_status)가 재계산.

  return jsonb_build_object(
    'success', true,
    'updated_books', coalesce(v_updated, 0),
    'skipped_product_ids', to_jsonb(coalesce(v_skipped, '{}'::bigint[]))
  );
end;
$$;

grant execute on function public.admin_bulk_set_products_visibility(bigint[], boolean) to authenticated;

notify pgrst, 'reload schema';

commit;
