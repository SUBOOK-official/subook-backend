-- 인기순/BEST: 최근 30일 결제완료 주문수 → 최근 7일 주문수 → 30일 판매수 → 찜 → 입고.
-- 입금대기·취소·전체/부분환불은 제외. 최근 구매가 없으면 최근 입고순.
-- 기존 함수 인자/반환형/권한, 검색(정확 학년도·초성·동의어·오타), 필터, 재고 기준 유지.
-- 테이블/데이터/RLS 변경 없음. legacy_sales_count 원장은 보존한다.
-- 롤백: 20260907162959_storefront_exact_year_search.sql의 list_public_store_products 본문 복원.
-- 근거: https://www.postgresql.org/docs/current/functions-window.html

begin;

create or replace function public.list_public_store_products(
  p_subjects text[] default null,
  p_book_types text[] default null,
  p_brands text[] default null,
  p_years integer[] default null,
  p_condition_grades text[] default null,
  p_search text default null,
  p_sort text default 'popular',
  p_limit integer default 24,
  p_offset integer default 0,
  p_instructors text[] default null,
  p_title_terms text[] default null
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
      -- 4자리 학년도는 유사어가 아니라 기존 연도 필터와 같은 정확 일치 조건이다.
      substring(coalesce(p_search, '') from '(?<![0-9])20[0-9]{2}(?![0-9])')::integer as search_year,
      lower(btrim(coalesce(p_search, ''))) as search_lower,
      public.extract_chosung(lower(btrim(coalesce(p_search, '')))) as search_chosung,
      (btrim(coalesce(p_search, '')) <> '' and btrim(coalesce(p_search, '')) !~ '[가-힣]') as is_chosung_only,
      -- 오타 임계(글자수 적응형): 첫 글자만 겹친 점수(1/(글자수+1))보다 높아야 통과
      greatest(0.25, 1.0 / (char_length(lower(btrim(coalesce(p_search, 'x')))) + 1) + 0.05)::real as typo_threshold
  ),
  -- 주문마다 같은 상품은 한 번만 센다. 판매 수량은 동률 보조 지표다.
  recent_sales as (
    select
      oi.product_id,
      count(distinct o.id) as order_count_30d,
      count(distinct o.id) filter (
        where coalesce(o.paid_at, o.pg_approved_at) >= now() - interval '7 days'
      ) as order_count_7d,
      sum(oi.quantity) as sales_count_30d
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.payment_status = 'paid'
      and o.status not in ('cancelled', 'refunded')
      and oi.refunded_at is null
      and coalesce(o.paid_at, o.pg_approved_at) >= now() - interval '30 days'
      and coalesce(o.paid_at, o.pg_approved_at) <= now()
    group by oi.product_id
  ),
  favorites as (
    select w.product_id, count(*) as favorite_count
    from public.wishlist_items w
    group by w.product_id
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
      -- 상품 매칭 점수: 부분(오타) 유사도 포함 — 정확 포함(0.8~1.0) > 오타(0.25~0.6) > 노이즈
      case
        when params.search_term = '' then 0::real
        else greatest(
          similarity(coalesce(p.search_text, ''), params.search_lower),
          word_similarity(params.search_lower, coalesce(p.search_text, '')),
          case when params.is_chosung_only
            then similarity(coalesce(p.search_chosung, ''), params.search_chosung)
            else 0
          end,
          case when position(params.search_lower in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
        )::real
      end as match_score
    from public.products p
    join public.books b
      on b.product_id = p.id
    cross join params
    where b.status = 'on_sale'
      and b.is_public = true
      and (params.search_year is null or p.published_year = params.search_year)
      and (coalesce(cardinality(p_subjects), 0) = 0 or p.subject = any(p_subjects))
      and (coalesce(cardinality(p_book_types), 0) = 0 or p.book_type = any(p_book_types))
      and (coalesce(cardinality(p_brands), 0) = 0 or p.brand = any(p_brands))
      and (coalesce(cardinality(p_years), 0) = 0 or p.published_year = any(p_years))
      -- 강사 랜딩: instructor_name 정확 일치 (2026-08-19)
      and (coalesce(cardinality(p_instructors), 0) = 0 or p.instructor_name = any(p_instructors))
      -- 시리즈 랜딩: 상품명 부분 일치 — 한/영 표기 중 하나라도 매칭 (2026-08-19)
      and (
        coalesce(cardinality(p_title_terms), 0) = 0
        or exists (
          select 1
          from unnest(p_title_terms) as series_term
          where p.title ilike '%' || series_term || '%'
        )
      )
      and (
        coalesce(cardinality(p_condition_grades), 0) = 0
        or b.condition_grade = any(p_condition_grades)
      )
      and (
        params.search_term = ''
        -- FTS: search_text 부분일치
        or coalesce(p.search_text, '') ilike '%' || params.search_lower || '%'
        -- 초성 검색 (ㅅㄷㅇㅈ → 시대인재)
        or (params.is_chosung_only and coalesce(p.search_chosung, '') ilike '%' || params.search_chosung || '%')
        -- 오타 허용: 부분(word) 유사도, 글자수 적응 임계 (2026-07-23)
        or word_similarity(params.search_lower, coalesce(p.search_text, '')) >= params.typo_threshold
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
      max(candidate_books.match_score) over (partition by candidate_books.product_id) as product_match_score,
      max(candidate_books.book_created_at) over (partition by candidate_books.product_id) as latest_book_created_at
    from candidate_books
  ),
  representative_products as (
    select
      ranked_books.*,
      coalesce(recent_sales.order_count_30d, 0) as order_count_30d,
      coalesce(recent_sales.order_count_7d, 0) as order_count_7d,
      coalesce(recent_sales.sales_count_30d, 0) as sales_count_30d,
      coalesce(favorites.favorite_count, 0) as favorite_count
    from ranked_books
    left join recent_sales on recent_sales.product_id = ranked_books.product_id
    left join favorites on favorites.product_id = ranked_books.product_id
    where ranked_books.representative_rank = 1
  ),
  scored_products as (
    select
      representative_products.*,
      -- 기존 RPC 반환형(int4)과 구버전 클라이언트 호환.
      -- 지표를 자릿수에 패킹하지 않고 정렬 순위를 점수로 바꾸므로 판매수 캡이 없다.
      -- 점수는 현재 필터 결과 안에서만 비교하는 순서값이며 판매량이 아니다.
      (2147483647 - row_number() over (
        order by
          order_count_30d desc,
          order_count_7d desc,
          sales_count_30d desc,
          -- 최근 구매가 없는 교재는 찜/과거 판매/할인 점수 대신 최근 입고순으로 탐색.
          case when order_count_30d > 0 then favorite_count else 0 end desc,
          latest_book_created_at desc,
          product_id desc
      ))::integer as product_popularity_score
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

commit;
