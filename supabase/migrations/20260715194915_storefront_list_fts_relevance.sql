-- 스토어 목록 RPC 검색 강화: FTS(trgm)+초성+오타 매칭 통합 + 관련도(relevance) 정렬
--
-- 배경(P0 카탈로그 500 탈출): 프론트 그리드가 500개 스냅샷 클라이언트 필터에 갇혀 있어
-- 서버 페이지네이션으로 전환한다. 목록 RPC(list_public_store_products)는 이미
-- 필터·정렬·offset/limit·total_count를 지원하지만 검색이 9-way ILIKE 부분일치뿐이라,
-- search_storefront_products(FTS+초성)의 매칭 품질을 이 RPC의 p_search로 흡수한다.
-- → 그리드는 단일 RPC로 검색+필터+정렬+페이지네이션을 모두 처리.
--
-- 변경점 (시그니처 동일 — 순수 CREATE OR REPLACE):
--   1) p_search 매칭: products.search_text/search_chosung(트리거 유지, GIN trgm 인덱스)
--      + similarity(>0.15) 오타 허용 + 기존 book 필드(option·연도) ILIKE 보존.
--   2) p_sort='relevance' 추가: 상품 단위 match_score(최대 유사도) 내림차순.
--      검색어가 없으면 match_score가 0이라 기존 fallback(최신순)과 동일하게 동작.
--   3) 기존 정렬(latest/price_low/price_high/popular) 및 반환 컬럼은 그대로.

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
      btrim(coalesce(p_search, '')) as search_term,
      lower(btrim(coalesce(p_search, ''))) as search_lower,
      public.extract_chosung(lower(btrim(coalesce(p_search, '')))) as search_chosung,
      (btrim(coalesce(p_search, '')) <> '' and btrim(coalesce(p_search, '')) !~ '[가-힣]') as is_chosung_only
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
      -- 검색어가 있을 때만 의미 있는 상품 매칭 점수 (search RPC와 동일 공식)
      case
        when params.search_term = '' then 0::real
        else greatest(
          similarity(coalesce(p.search_text, ''), params.search_lower),
          case when params.is_chosung_only
            then similarity(coalesce(p.search_chosung, ''), params.search_chosung)
            else 0
          end,
          case when position(params.search_lower in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
        )::real
      end as match_score,
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
        -- FTS: search_text 부분일치(대소문자·공백 정규화는 트리거가 수행)
        or coalesce(p.search_text, '') ilike '%' || params.search_lower || '%'
        -- 초성 검색 (ㅅㄷㅇㅈ → 시대인재)
        or (params.is_chosung_only and coalesce(p.search_chosung, '') ilike '%' || params.search_chosung || '%')
        -- 오타 허용 (trgm 유사도)
        or similarity(coalesce(p.search_text, ''), params.search_lower) > 0.15
        -- 기존 ILIKE에서만 커버되던 book 단위 필드 보존 (회차 옵션·연도 검색 회귀 방지)
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
      max(candidate_books.match_score) over (partition by candidate_books.product_id) as product_match_score,
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
      case when params.sort_key = 'relevance' then scored_products.product_match_score end desc nulls last,
      case when params.sort_key = 'latest' then scored_products.latest_book_created_at end desc nulls last,
      case when params.sort_key = 'price_low' then scored_products.price end asc nulls last,
      case when params.sort_key = 'price_high' then scored_products.price end desc nulls last,
      case when params.sort_key = 'popular' then scored_products.product_popularity_score end desc nulls last,
      -- relevance 동점(동일 match_score) 시 인기 → 최신 순으로 이어서 안정 정렬
      case when params.sort_key = 'relevance' then scored_products.product_popularity_score end desc nulls last,
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
