-- 상품 등록 검색 결과에 기존 상세사진(detail_image_urls) 포함 (2026-07-21)
--
-- 배경: 등록 위저드에서 이미 상세사진이 있는 기존 상품에 재고를 추가할 때, 사진 단계가
--   빈 칸으로 떠서 (1) 이미 등록돼 있는지 운영자가 알 수 없고 (2) 그대로 등록하면 새 책의
--   inspection_image_urls가 빈 배열이 되어 같은 상품인데 권마다 상세사진이 달라지는
--   정합성 문제가 있었다. (상세사진은 책 종류 단위 — [[project-product-option-integrity]])
--
-- 변경: admin_search_products_for_register 결과에 detail_image_urls 추가.
--   상품 소속 책 중 상세사진이 있는 첫 책의 세트를 대표값으로 내려준다. 프론트가 이걸
--   기존 교재 추가 항목의 상세사진에 프리필 → 화면 표시 + 신규 책이 동일 세트를 상속.
--   (CREATE OR REPLACE — 시그니처 동일, 비파괴)

begin;

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

  select coalesce(jsonb_agg(row_data order by row_data->>'title'), '[]'::jsonb)
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
    order by p.title
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.admin_search_products_for_register(text, integer) to authenticated;

notify pgrst, 'reload schema';

commit;
