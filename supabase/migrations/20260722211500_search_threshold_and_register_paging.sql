-- 검색 개선 2건 (2026-07-23 운영자·대표 피드백)
--
-- 1) 공개 검색 오타 임계를 글자수 적응형으로 — "이신혁 검색에 무관 책 54종" 수리
--    증상: '이신혁' 검색 시 63건 중 9건만 진짜, 나머지는 이미지T·이명학·이감·이투스 등
--    '이'로 시작하는 단어를 가진 전 상품.
--    원인(실측): word_similarity >= 0.25 고정 임계. 3글자 검색어는 trigram이 4개뿐이라
--    첫 글자만 같은 무관 단어도 경계 trigram("␣␣이") 1개 공유로 정확히 0.250이 나옴.
--    (기존 0.25 보정은 4글자 오타 '시데인재'=0.250 기준 — 4글자에선 무관 단어가 0.20이라
--    유효했지만 3글자에선 오타와 무관을 같은 점수로 만듦.)
--    수리: 임계 = greatest(0.25, 1/(글자수+1) + 0.05) — "첫 글자만 겹친 점수(1/trigram수)
--    보다 유의미하게 높아야" 원칙. 실측 검증(프로덕션):
--      · 3자 '이신혁': 임계 0.30 → 무관(0.250) 제외, 오타 '이신헉'(0.500) 유지, 63→9건
--      · 4자 '시데인재': 임계 0.25 그대로 → 기존 오타 보정 회귀 없음
--      · 2자: 임계 0.383 → 첫 글자 일치 노이즈(0.333) 차단
--    적용: list_public_store_products(그리드) + search_storefront_products(자동완성),
--    둘 다 시그니처 불변 CREATE OR REPLACE. 임계식 외 변경 없음.
--
-- 2) 어드민 등록 검색 p_offset 추가 — 상한 안내문 대신 "더 보기" 페이지네이션
--    상한(50)의 이유: 결과 행마다 옵션 집계·상세사진·등급 대표값 등 상관 서브쿼리가
--    돌아 무제한 반환은 타이핑 디바운스마다 느려짐. 상한은 유지하되 offset으로 다음
--    페이지를 이어 붙일 수 있게 한다. 파라미터 추가 = 시그니처 변경이므로 구버전 drop
--    (PostgREST 오버로드 모호성 방지). offset 안정성을 위해 정렬에 id 타이브레이커 추가.

begin;

-- ── 1a) 그리드 목록 RPC — word_similarity 임계만 글자수 적응형으로 ─────────────

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
      (btrim(coalesce(p_search, '')) <> '' and btrim(coalesce(p_search, '')) !~ '[가-힣]') as is_chosung_only,
      -- 오타 임계(글자수 적응형): 첫 글자만 겹친 점수(1/(글자수+1))보다 높아야 통과
      greatest(0.25, 1.0 / (char_length(lower(btrim(coalesce(p_search, 'x')))) + 1) + 0.05)::real as typo_threshold
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

-- ── 1b) 자동완성 RPC — 동일 임계 적용 ────────────────────────────────────────

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
  v_typo_threshold real;
begin
  if v_q = '' then
    return;
  end if;

  v_q_chosung := public.extract_chosung(v_q);
  v_is_chosung_only := v_q !~ '[가-힣]';
  -- 오타 임계(글자수 적응형) — 그리드 RPC와 동일 공식 (2026-07-23)
  v_typo_threshold := greatest(0.25, 1.0 / (char_length(v_q) + 1) + 0.05)::real;

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
        -- 오타 허용: 부분 유사도, 글자수 적응 임계 (2026-07-23)
        or word_similarity(v_q, coalesce(p.search_text, '')) >= v_typo_threshold
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

-- ── 2) 어드민 등록 검색 — p_offset 추가 + id 타이브레이커 ─────────────────────

drop function if exists public.admin_search_products_for_register(text, integer);

create or replace function public.admin_search_products_for_register(
  p_search text default null,
  p_limit integer default 20,
  p_offset integer default 0
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
      order by (row_data->>'published_year')::int desc nulls last, row_data->>'title', (row_data->>'id')::bigint),
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
    order by p.published_year desc nulls last, p.title, p.id
    limit greatest(1, least(coalesce(p_limit, 20), 100))
    offset greatest(0, coalesce(p_offset, 0))
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.admin_search_products_for_register(text, integer, integer) to authenticated;

notify pgrst, 'reload schema';

commit;
