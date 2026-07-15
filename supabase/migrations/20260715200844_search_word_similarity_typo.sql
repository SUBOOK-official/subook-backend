-- 검색 오타 매칭 보강: similarity → word_similarity (부분 유사도)
--
-- 문제: trgm similarity(전체 문자열 비교)는 "짧은 검색어 vs 긴 search_text"에서
-- 분모(전체 trigram 합집합)가 커져 실측 0.03~0.06 수준 — 임계 0.15에 절대 못 미쳐
-- 오타 검색이 사실상 죽어 있었다 (예: '시데인재' → 0건).
--
-- 실측(2026-07-16, 프로덕션 데이터):
--   word_similarity('시데인재', search_text)  = 0.25  (중간 글자 오타)
--   word_similarity('시대인제', search_text)  = 0.60  (끝 글자 오타)
--   '시데인재' @>=0.25 → 242건(정답 218 + 노이즈 ~24, 관련도 정렬로 정답이 상위)
--   '마더텅수학'(붙여쓰기) @>=0.25 → 2건 (기존 exact 0건이던 것을 회수)
-- → 임계 0.25(>=)로 채택. 노이즈는 match_score 정렬이 하위로 밀어낸다.
--
-- 적용 대상: list_public_store_products(그리드), search_storefront_products(자동완성)
-- 둘 다 시그니처 불변 CREATE OR REPLACE.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 그리드 목록 RPC — 검색 술어 + match_score에 word_similarity 추가
-- ─────────────────────────────────────────────────────────────────────────────
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
        -- FTS: search_text 부분일치
        or coalesce(p.search_text, '') ilike '%' || params.search_lower || '%'
        -- 초성 검색 (ㅅㄷㅇㅈ → 시대인재)
        or (params.is_chosung_only and coalesce(p.search_chosung, '') ilike '%' || params.search_chosung || '%')
        -- 오타 허용: 부분(word) 유사도 — 실측 기반 임계 0.25
        or word_similarity(params.search_lower, coalesce(p.search_text, '')) >= 0.25
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 자동완성 검색 RPC — 동일한 word_similarity 보강 (시그니처 불변)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.search_storefront_products(
  p_query text,
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (
  id bigint,
  title text,
  option text,
  subject text,
  brand text,
  book_type text,
  published_year integer,
  instructor_name text,
  cover_image_url text,
  status text,
  price integer,
  condition_grade text,
  available_count integer,
  match_score real
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_q_chosung text;
  v_is_chosung_only boolean;
begin
  if v_q = '' then
    return;
  end if;

  v_q_chosung := public.extract_chosung(v_q);
  v_is_chosung_only := v_q !~ '[가-힣]';

  return query
  with matched as (
    select
      p.id, p.title, p.option, p.subject, p.brand, p.book_type,
      p.published_year, p.instructor_name, p.cover_image_url, p.status,
      greatest(
        similarity(p.search_text, v_q),
        word_similarity(v_q, coalesce(p.search_text, '')),
        case when v_is_chosung_only then similarity(p.search_chosung, v_q_chosung) else 0 end,
        case when position(v_q in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
      )::real as match_score
    from public.products p
    where p.status <> 'hidden'
      and (
        p.search_text ilike '%' || v_q || '%'
        or (v_is_chosung_only and p.search_chosung ilike '%' || v_q_chosung || '%')
        -- 오타 허용: 전체 similarity(긴 텍스트에서 무력) 대신 부분 유사도, 실측 임계 0.25
        or word_similarity(v_q, coalesce(p.search_text, '')) >= 0.25
      )
  ),
  enriched as (
    select
      m.*,
      (
        select b.price from public.books b
        where b.product_id = m.id
          and b.status = 'on_sale'
          and b.is_public = true
        order by b.price asc nulls last, b.id asc
        limit 1
      ) as book_price,
      (
        select b.condition_grade from public.books b
        where b.product_id = m.id
          and b.status = 'on_sale'
          and b.is_public = true
        order by b.price asc nulls last, b.id asc
        limit 1
      ) as book_condition_grade,
      (
        select count(*)::integer from public.books b
        where b.product_id = m.id
          and b.status = 'on_sale'
          and b.is_public = true
      ) as available_count
    from matched m
  )
  select
    e.id, e.title, e.option, e.subject, e.brand, e.book_type,
    e.published_year, e.instructor_name, e.cover_image_url, e.status,
    e.book_price as price,
    e.book_condition_grade as condition_grade,
    e.available_count,
    e.match_score
  from enriched e
  order by e.match_score desc, e.available_count desc, e.id desc
  limit greatest(p_limit, 1)
  offset greatest(p_offset, 0);
end;
$$;

notify pgrst, 'reload schema';
