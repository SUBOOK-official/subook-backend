-- 진짜 인기순 정렬 — 실제 판매수(식스샵 과거 + 신규 주문) 기반.
--
-- 배경: 기존 list_public_store_products 의 popularity_score 는 실제 판매/조회/찜이 아니라
--   등급·할인·검수 기반 "품질 점수"였다. 프론트(HomeStoreGrid)는 이 popularity_score 를
--   fallback 정렬키로 쓰므로, 여기서 popularity_score 를 "판매수 우선" 점수로 재정의하면
--   함수 시그니처/프론트 변경 없이 인기순이 실제 판매 기준으로 바뀐다.
--
-- 정렬 우선순위: 판매수(식스샵 legacy + 신규 order_items) → 찜(wishlist) → 품질점수(등급·할인·검수).
-- 단일 int4 컬럼(popularity_score)에 패킹: sales*1e7 + fav*1e4 + quality. 각 항 캡으로 int4 오버플로 방지.
--   sales<=200(*1e7=2.0e9), fav<=999(*1e4=9.99e6), quality<=9999. 합 최대 ~2.01e9 < int4 max(2.147e9).
--
-- 비파괴: ADD COLUMN IF NOT EXISTS, 데이터 백필 UPDATE(사용자 승인 완료), CREATE OR REPLACE FUNCTION.

-- 1) 식스샵 과거 판매수 저장 컬럼
alter table public.products
  add column if not exists legacy_sales_count integer not null default 0;

comment on column public.products.legacy_sales_count is
  '식스샵(구 사이트) 과거 판매 수량 — 인기순 정렬 반영용. 2026-07-02 주문완료 export 백필.';

-- 2) 식스샵 과거 판매수 백필 (엑셀 '완료된 주문' → 현재 재고 있는 상품에 매칭, 63개 상품 236권)
update public.products p
set legacy_sales_count = v.cnt
from (values
  (118,26),(90,15),(20,11),(1322,11),(64,10),(77,10),(47,8),(19,8),(1323,8),(121,8),(284,8),(117,8),(9,7),(113,6),(2,6),(110,6),(22,5),(38,5),(430,4),(114,4),(70,4),(91,3),(69,3),(31,3),(125,2),(42,2),(141,2),(1251,2),(200,2),(59,2),(32,2),(13,2),(71,2),(1253,2),(453,1),(329,1),(100,1),(92,1),(116,1),(115,1),(67,1),(396,1),(323,1),(57,1),(103,1),(23,1),(1337,1),(12,1),(1324,1),(262,1),(8,1),(1159,1),(66,1),(157,1),(199,1),(275,1),(278,1),(122,1),(205,1),(154,1),(1279,1),(1280,1),(1368,1)
) as v(id, cnt)
where p.id = v.id;

-- 3) RPC 재정의: popularity_score = 판매수 우선 패킹 점수
create or replace function public.list_public_store_products(
  p_subjects text[] default null,
  p_book_types text[] default null,
  p_brands text[] default null,
  p_years integer[] default null,
  p_condition_grades text[] default null,
  p_search text default null,
  p_sort text default 'popular',
  p_limit integer default 24,
  p_offset integer default 0
)
returns table (
  id bigint,
  product_id bigint,
  title text,
  option text,
  subject text,
  brand text,
  book_type text,
  published_year integer,
  instructor_name text,
  condition_grade text,
  price integer,
  original_price integer,
  discount_rate integer,
  cover_image_url text,
  inspection_image_urls text[],
  writing_percentage integer,
  has_damage boolean,
  inspection_notes text,
  inspected_at timestamptz,
  created_at timestamptz,
  popularity_score integer,
  available_option_count integer,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      lower(coalesce(btrim(p_sort), 'popular')) as sort_key,
      btrim(coalesce(p_search, '')) as search_term
  ),
  candidate_books as (
    select
      p.id as product_id,
      p.title,
      p.option,
      p.subject,
      p.brand,
      p.book_type,
      p.published_year,
      p.instructor_name,
      p.cover_image_url as product_cover_image_url,
      coalesce(p.legacy_sales_count, 0) as legacy_sales_count,
      b.id as book_id,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url as book_cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at as book_created_at,
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank,
      (
        case coalesce(b.condition_grade, '')
          when 'S' then 300
          when 'A_PLUS' then 200
          when 'A' then 100
          else 0
        end
        + greatest(0, coalesce(b.original_price - b.price, 0) / 100)
        + greatest(0, 100 - coalesce(b.writing_percentage, 100))
        + case
            when b.inspected_at is null then 0
            else greatest(0, 30 - least(30, floor(extract(day from now() - b.inspected_at))::integer))
          end
      )::integer as quality_score
    from public.products p
    join public.books b
      on b.product_id = p.id
    cross join params
    where b.status = 'on_sale'
      and b.is_public = true
      and (coalesce(cardinality(p_subjects), 0) = 0 or p.subject = any(p_subjects))
      and (coalesce(cardinality(p_book_types), 0) = 0 or p.book_type = any(p_book_types))
      and (coalesce(cardinality(p_brands), 0) = 0 or p.brand = any(p_brands))
      and (coalesce(cardinality(p_years), 0) = 0 or p.published_year = any(p_years))
      and (
        coalesce(cardinality(p_condition_grades), 0) = 0
        or b.condition_grade = any(p_condition_grades)
      )
      and (
        params.search_term = ''
        or p.title ilike '%' || params.search_term || '%'
        or coalesce(p.option, '') ilike '%' || params.search_term || '%'
        or coalesce(p.subject, '') ilike '%' || params.search_term || '%'
        or coalesce(p.brand, '') ilike '%' || params.search_term || '%'
        or coalesce(p.book_type, '') ilike '%' || params.search_term || '%'
        or coalesce(p.instructor_name, '') ilike '%' || params.search_term || '%'
        or coalesce(b.condition_grade, '') ilike '%' || params.search_term || '%'
        or coalesce(b.option, '') ilike '%' || params.search_term || '%'
        or coalesce(b.published_year::text, '') ilike '%' || params.search_term || '%'
      )
  ),
  ranked_books as (
    select
      candidate_books.*,
      row_number() over (
        partition by candidate_books.product_id
        order by
          candidate_books.price asc nulls last,
          candidate_books.condition_rank asc,
          candidate_books.book_created_at desc,
          candidate_books.book_id desc
      ) as representative_rank,
      count(*) over (partition by candidate_books.product_id) as available_option_count,
      max(candidate_books.quality_score) over (partition by candidate_books.product_id) as product_quality_score,
      max(candidate_books.book_created_at) over (partition by candidate_books.product_id) as latest_book_created_at
    from candidate_books
  ),
  representative_products as (
    select
      ranked_books.*,
      -- 실제 판매수 = 식스샵 과거 판매(legacy) + 신규 사이트 주문(취소/환불 제외)
      (
        ranked_books.legacy_sales_count
        + coalesce((
            select count(*)
            from public.order_items oi
            join public.orders o on o.id = oi.order_id
            where oi.product_id = ranked_books.product_id
              and o.status not in ('cancelled', 'refunded')
          ), 0)
      )::integer as product_sales_count,
      -- 찜 수
      coalesce((
        select count(*)
        from public.wishlist_items w
        where w.product_id = ranked_books.product_id
      ), 0)::integer as product_favorite_count
    from ranked_books
    where ranked_books.representative_rank = 1
  ),
  scored_products as (
    select
      representative_products.*,
      (
        least(200, greatest(0, representative_products.product_sales_count)) * 10000000
        + least(999, greatest(0, representative_products.product_favorite_count)) * 10000
        + least(9999, greatest(0, representative_products.product_quality_score))
      )::integer as product_popularity_score
    from representative_products
  ),
  ordered as (
    select
      scored_products.*
    from scored_products
    cross join params
    order by
      case when params.sort_key = 'latest' then scored_products.latest_book_created_at end desc nulls last,
      case when params.sort_key = 'price_low' then scored_products.price end asc nulls last,
      case when params.sort_key = 'price_high' then scored_products.price end desc nulls last,
      case when params.sort_key = 'popular' then scored_products.product_popularity_score end desc nulls last,
      scored_products.latest_book_created_at desc,
      scored_products.product_id desc
  )
  select
    ordered.product_id as id,
    ordered.product_id,
    ordered.title,
    ordered.option,
    ordered.subject,
    ordered.brand,
    ordered.book_type,
    ordered.published_year,
    ordered.instructor_name,
    ordered.condition_grade,
    ordered.price,
    ordered.original_price,
    ordered.discount_rate,
    coalesce(ordered.book_cover_image_url, ordered.product_cover_image_url) as cover_image_url,
    ordered.inspection_image_urls,
    ordered.writing_percentage,
    ordered.has_damage,
    ordered.inspection_notes,
    ordered.inspected_at,
    ordered.latest_book_created_at as created_at,
    ordered.product_popularity_score as popularity_score,
    ordered.available_option_count,
    count(*) over()::integer as total_count
  from ordered
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 24), 500));
$$;

notify pgrst, 'reload schema';
