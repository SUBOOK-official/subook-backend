-- 전일학원 모의고사는 전량 예약/판매 후에도 품절 상품으로 탐색·상세 조회한다.
-- 판매 시 books.is_public=false가 강제되므로 reserved/settled 기록을 표시용으로만 사용한다.
-- 숨긴 on_sale 재고·폐기 재고는 공개하지 않으며, 가용 수량은 공개 on_sale만 집계한다.
-- 주문/재고/상품 상태 트리거와 RLS·RPC 시그니처/권한은 변경하지 않는다.
-- 기존 검색·학년도·컬렉션 필터·최근 주문 인기순을 보존한다.
-- 롤백: 직전 list/get detail/search RPC 정의를 복원한다.
-- 근거: https://supabase.com/docs/reference/cli/supabase-db-push

begin;

CREATE OR REPLACE FUNCTION public.list_public_store_products(p_subjects text[] DEFAULT NULL::text[], p_book_types text[] DEFAULT NULL::text[], p_brands text[] DEFAULT NULL::text[], p_years integer[] DEFAULT NULL::integer[], p_condition_grades text[] DEFAULT NULL::text[], p_search text DEFAULT NULL::text, p_sort text DEFAULT 'popular'::text, p_limit integer DEFAULT 24, p_offset integer DEFAULT 0, p_instructors text[] DEFAULT NULL::text[], p_title_terms text[] DEFAULT NULL::text[])
 RETURNS TABLE(id bigint, product_id bigint, title text, option text, subject text, brand text, book_type text, published_year integer, instructor_name text, condition_grade text, price integer, original_price integer, discount_rate integer, cover_image_url text, inspection_image_urls text[], writing_percentage integer, has_damage boolean, inspection_notes text, inspected_at timestamp with time zone, created_at timestamp with time zone, popularity_score integer, available_option_count integer, total_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      (b.status = 'on_sale' and b.is_public) as is_available,
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
    where ((b.status = 'on_sale' and b.is_public = true)
      or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        )))
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
      count(*) filter (where candidate_books.is_available) over (partition by candidate_books.product_id) as available_option_count,
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
$function$;

CREATE OR REPLACE FUNCTION public.get_public_store_product_detail(p_product_id bigint)
 RETURNS TABLE(id bigint, product_id bigint, title text, option text, subject text, brand text, book_type text, published_year integer, instructor_name text, condition_grade text, price integer, original_price integer, discount_rate integer, cover_image_url text, inspection_image_urls text[], writing_percentage integer, has_damage boolean, inspection_notes text, inspected_at timestamp with time zone, created_at timestamp with time zone, related_books jsonb, option_books jsonb, available_option_count integer, sold_out_option_count integer, total_option_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with target_product as (
    select p.*
    from public.products p
    where p.id = p_product_id
      and exists (
        select 1
        from public.books b
        where b.product_id = p.id
          and ((b.status = 'on_sale' and b.is_public = true)
          or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        )))
      )
    limit 1
  ),
  representative_book as (
    select
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
      b.created_at as book_created_at
    from public.books b
    join target_product p
      on p.id = b.product_id
    where ((b.status = 'on_sale' and b.is_public = true)
      or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        )))
    order by
      public.storefront_condition_grade_rank(b.condition_grade),
      b.price asc nulls last,
      b.created_at desc,
      b.id desc
    limit 1
  ),
  option_book_rows as (
    select
      b.id as book_id,
      b.product_id,
      b.title,
      b.option,
      b.subject,
      b.brand,
      b.book_type,
      b.published_year,
      b.instructor_name,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at,
      (b.status = 'on_sale' and b.is_public) as is_available,
      case
        when b.status = 'on_sale' and b.is_public then 'selling'
        else 'sold_out'
      end as availability_status,
      case
        when b.status = 'on_sale' and b.is_public then 1
        else 0
      end as stock_count,
      case
        when b.status = 'on_sale' and b.is_public then 0
        else 1
      end as availability_rank,
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank
    from public.books b
    join target_product p
      on p.id = b.product_id
    where b.is_public = true or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        ))
  ),
  option_books as (
    select
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'book_id', option_book_rows.book_id,
            'product_id', option_book_rows.product_id,
            'title', option_book_rows.title,
            'option', option_book_rows.option,
            'subject', option_book_rows.subject,
            'brand', option_book_rows.brand,
            'book_type', option_book_rows.book_type,
            'published_year', option_book_rows.published_year,
            'instructor_name', option_book_rows.instructor_name,
            'condition_grade', option_book_rows.condition_grade,
            'price', option_book_rows.price,
            'original_price', option_book_rows.original_price,
            'discount_rate', option_book_rows.discount_rate,
            'cover_image_url', option_book_rows.cover_image_url,
            'inspection_image_urls', option_book_rows.inspection_image_urls,
            'writing_percentage', option_book_rows.writing_percentage,
            'has_damage', option_book_rows.has_damage,
            'inspection_notes', option_book_rows.inspection_notes,
            'inspected_at', option_book_rows.inspected_at,
            'created_at', option_book_rows.created_at,
            'status', option_book_rows.availability_status,
            'is_available', option_book_rows.is_available,
            'stock_count', option_book_rows.stock_count
          )
          order by
            option_book_rows.availability_rank,
            option_book_rows.condition_rank,
            option_book_rows.price asc nulls last,
            option_book_rows.created_at desc,
            option_book_rows.book_id desc
        ),
        '[]'::jsonb
      ) as option_books,
      count(*) filter (where option_book_rows.is_available)::integer as available_option_count,
      count(*) filter (where not option_book_rows.is_available)::integer as sold_out_option_count,
      count(*)::integer as total_option_count
    from option_book_rows
  ),
  related_books as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', related_product.id,
          'product_id', related_product.product_id,
          'title', related_product.title,
          'option', related_product.option,
          'subject', related_product.subject,
          'brand', related_product.brand,
          'book_type', related_product.book_type,
          'published_year', related_product.published_year,
          'instructor_name', related_product.instructor_name,
          'condition_grade', related_product.condition_grade,
          'price', related_product.price,
          'original_price', related_product.original_price,
          'discount_rate', related_product.discount_rate,
          'cover_image_url', related_product.cover_image_url,
          'inspection_image_urls', related_product.inspection_image_urls,
          'writing_percentage', related_product.writing_percentage,
          'has_damage', related_product.has_damage,
          'inspection_notes', related_product.inspection_notes,
          'inspected_at', related_product.inspected_at,
          'created_at', related_product.created_at,
          'popularity_score', related_product.popularity_score,
          'available_option_count', related_product.available_option_count
        )
        order by related_product.popularity_score desc, related_product.created_at desc, related_product.id desc
      ),
      '[]'::jsonb
    ) as related_books
    from target_product tp
    cross join lateral (
      select *
      from public.list_public_store_products(
        array[tp.subject],
        array[tp.book_type],
        array[tp.brand],
        array[tp.published_year],
        null,
        null,
        'popular',
        6,
        0
      )
      where id <> tp.id
    ) related_product
  )
  select
    target_product.id,
    target_product.id,
    target_product.title,
    target_product.option,
    target_product.subject,
    target_product.brand,
    target_product.book_type,
    target_product.published_year,
    target_product.instructor_name,
    representative_book.condition_grade,
    representative_book.price,
    representative_book.original_price,
    representative_book.discount_rate,
    coalesce(representative_book.book_cover_image_url, target_product.cover_image_url) as cover_image_url,
    representative_book.inspection_image_urls,
    representative_book.writing_percentage,
    representative_book.has_damage,
    representative_book.inspection_notes,
    representative_book.inspected_at,
    representative_book.book_created_at as created_at,
    related_books.related_books,
    option_books.option_books,
    option_books.available_option_count,
    option_books.sold_out_option_count,
    option_books.total_option_count
  from target_product
  left join representative_book on true
  cross join related_books
  cross join option_books;
$function$;

CREATE OR REPLACE FUNCTION public.search_storefront_products(p_query text, p_limit integer DEFAULT 30, p_offset integer DEFAULT 0)
 RETURNS TABLE(id bigint, title text, option text, subject text, brand text, book_type text, published_year integer, instructor_name text, cover_image_url text, status text, price integer, condition_grade text, available_count integer, match_score real)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_q_chosung text;
  v_search_year integer := substring(v_q from '(?<![0-9])20[0-9]{2}(?![0-9])')::integer;
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
      p.published_year, p.instructor_name, p.cover_image_url,
      case when p.status = 'hidden' then 'sold_out' else p.status end as status,
      greatest(
        similarity(p.search_text, v_q),
        word_similarity(v_q, coalesce(p.search_text, '')),
        case when v_is_chosung_only then similarity(p.search_chosung, v_q_chosung) else 0 end,
        case when position(v_q in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
      )::real as match_score
    from public.products p
    where (p.status <> 'hidden' or exists (
      select 1 from public.books b where b.product_id = p.id and (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        ))
    ))
      -- 자동완성과 목록의 학년도 범위를 일치시킨다. 복합 검색에도 적용한다.
      and (v_search_year is null or p.published_year = v_search_year)
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
          and ((b.status = 'on_sale' and b.is_public = true)
          or (m.brand = '전일학원' and m.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = m.id and unsold.status = 'on_sale'
        )))
        order by b.price asc nulls last, b.id asc
        limit 1
      ) as book_price,
      (
        select b.condition_grade from public.books b
        where b.product_id = m.id
          and ((b.status = 'on_sale' and b.is_public = true)
          or (m.brand = '전일학원' and m.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = m.id and unsold.status = 'on_sale'
        )))
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
$function$;

commit;
