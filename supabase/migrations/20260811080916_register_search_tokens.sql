-- 어드민 등록 검색 — 띄어쓴 여러 단어를 AND 매칭 (2026-08-11 운영자 피드백)
--
-- 증상: "서바이벌 물리학"으로 검색하면 "2026 시대인재 서바이벌 모의고사 물리학1"이
--       안 나온다. 운영자는 제목 전체를 외우지 않고 기억나는 단어만 띄어서 친다.
-- 원인: WHERE가 검색어 전체를 한 덩어리로 ILIKE '%…%' 매칭 → 제목에 그 문구가
--       연속으로 들어있어야만 걸린다.
-- 수리: 공백으로 토큰을 끊어 "모든 토큰이 각각 포함"(AND)으로 바꾼다. 매칭 대상은
--       products.search_text (title+option+subject+brand+book_type+instructor_name
--       소문자 + 동의어 별칭, compose_product_search_text가 단일 소스).
--       → 별칭 사전(search_synonyms)도 자동으로 어드민 검색에 반영된다.
--       정렬은 문구 전체가 그대로 들어간 상품을 먼저 (그 뒤 순서는 기존과 동일).
--
-- 시그니처 불변 CREATE OR REPLACE — 반환 형태·프론트 계약 변경 없음.

begin;

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
  v_phrase text;
  v_tokens text[];
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_search := nullif(btrim(coalesce(p_search, '')), '');
  if v_search is null then
    return '[]'::jsonb;
  end if;

  v_phrase := lower(v_search);
  -- 공백 기준 토큰 (예: '서바이벌 물리학' → {서바이벌, 물리학})
  v_tokens := array(
    select lower(btrim(t))
    from unnest(regexp_split_to_array(v_search, '\s+')) as t
    where btrim(t) <> ''
  );

  select coalesce(
    jsonb_agg(sub.row_data
      order by sub.phrase_rank, sub.year_sort desc nulls last, sub.title_sort, sub.id_sort),
    '[]'::jsonb)
  into v_result
  from (
    select
      jsonb_build_object(
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
      ) as row_data,
      -- 문구 전체가 그대로 들어간 상품을 위로
      case when hay.text like '%' || v_phrase || '%' then 0 else 1 end as phrase_rank,
      p.published_year as year_sort,
      p.title as title_sort,
      p.id as id_sort
    from public.products p
    -- 매칭 대상 텍스트 — search_text가 비어있는 옛 행을 위해 원본 조립으로 폴백
    cross join lateral (
      select coalesce(
        nullif(p.search_text, ''),
        lower(concat_ws(' ',
          coalesce(p.title, ''),
          coalesce(p.option, ''),
          coalesce(p.subject, ''),
          coalesce(p.brand, ''),
          coalesce(p.book_type, ''),
          coalesce(p.instructor_name, '')
        ))
      ) as text
    ) hay
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
      select bool_and(hay.text like '%' || tok || '%')
      from unnest(v_tokens) as tok
    )
    order by
      case when hay.text like '%' || v_phrase || '%' then 0 else 1 end,
      p.published_year desc nulls last,
      p.title,
      p.id
    limit greatest(1, least(coalesce(p_limit, 20), 100))
    offset greatest(0, coalesce(p_offset, 0))
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.admin_search_products_for_register(text, integer, integer) to authenticated;

notify pgrst, 'reload schema';

commit;
