-- 품절된 옵션도 기존 교재에 재입고할 수 있도록 보존하고 옵션별 가격 근거를 반환한다.
-- 현재 재고는 on_sale만 집계. 결제/수동 판매 스냅샷과 과거 등록가는 구분한다.
-- 데이터·RLS 변경 없음. 되돌릴 때는 20260811080916의 검색 함수 정의를 재적용한다.
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
  if v_search is null then return '[]'::jsonb; end if;
  v_phrase := lower(v_search);
  v_tokens := array(
    select lower(btrim(t)) from unnest(regexp_split_to_array(v_search, '\s+')) t
    where btrim(t) <> ''
  );

  -- 검색/페이지 제한을 먼저 적용해 해당 상품의 이력만 집계한다.
  with matched as materialized (
    select p.*, case when hay.text like '%' || v_phrase || '%' then 0 else 1 end phrase_rank
    from public.products p
    cross join lateral (
      select coalesce(nullif(p.search_text, ''),
        lower(concat_ws(' ', p.title, p.option, p.subject, p.brand, p.book_type, p.instructor_name))) text
    ) hay
    where (select bool_and(hay.text like '%' || tok || '%') from unnest(v_tokens) tok)
    order by phrase_rank, p.published_year desc nulls last, p.title, p.id
    limit greatest(1, least(coalesce(p_limit, 20), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'title', p.title, 'option', p.option,
    'subject', p.subject, 'brand', p.brand, 'book_type', p.book_type,
    'published_year', p.published_year, 'instructor_name', p.instructor_name,
    'cover_image_url', p.cover_image_url,
    'detail_image_urls', coalesce(
      (select b.inspection_image_urls from public.books b
       where b.product_id = p.id and array_length(b.inspection_image_urls, 1) > 0
       order by b.id limit 1), '{}'::text[]),
    'representative_original_price', agg.rep_original,
    'representative_grade', coalesce(
      (select mode() within group (order by b.condition_grade)
       from public.books b where b.product_id = p.id and b.status = 'on_sale'), 'S'),
    'inventory_count', coalesce(agg.stock_total, 0),
    'options', coalesce(agg.options, '[]'::jsonb)
  ) order by p.phrase_rank, p.published_year desc nulls last, p.title, p.id), '[]'::jsonb)
  into v_result
  from matched p
  left join lateral (
    with inventory as materialized (
      select b.*, nullif(btrim(b.option), '') option_key
      from public.books b where b.product_id = p.id
    ), paid_sales as materialized (
      -- 주문 당시 옵션·가격·등급을 사용한다. 취소/환불/미결제는 판매 실적에서 제외.
      select oi.id, oi.book_id, nullif(btrim(oi.option_label), '') option_key,
        oi.unit_price price, oi.condition_grade,
        coalesce(o.paid_at, o.created_at) sold_at
      from public.order_items oi join public.orders o on o.id = oi.order_id
      where oi.product_id = p.id and oi.refunded_at is null and oi.unit_price > 0
        and o.payment_status = 'paid'
        and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
    ), sales as (
      select 'order' source, s.id, s.option_key, s.price, s.condition_grade, s.sold_at
      from paid_sales s
      union all
      -- 이전 식스샵/수동 판매도 반영하되 같은 권의 주문 판매를 중복 집계하지 않는다.
      select 'manual', ms.id, b.option_key, ms.sale_amount, b.condition_grade,
        coalesce(ms.sold_at::timestamptz, ms.created_at)
      from public.manual_settlements ms join inventory b on b.id = ms.book_id
      where b.status = 'settled' and ms.status <> 'cancelled' and ms.sale_amount > 0
        and not exists (select 1 from paid_sales s where s.book_id = b.id)
    ), option_keys as (
      select option_key from inventory
      union
      select option_key from sales
    )
    select sum(i.stock_count) stock_total, max(i.original_price) rep_original,
      jsonb_agg(jsonb_build_object(
        'option', k.option_key,
        'stock_count', i.stock_count,
        -- price는 기존 클라이언트와 호환되는 입력 기본값. 근거 필드는 별도로 보존.
        'price', coalesce(i.current_price, s.last_sold_price, i.last_recorded_price),
        'original_price', i.original_price,
        'current_price', i.current_price,
        'last_recorded_price', i.last_recorded_price,
        'last_sold_price', s.last_sold_price,
        'last_sold_at', s.last_sold_at,
        'last_sold_grade', s.last_sold_grade,
        'sales_count', s.sales_count,
        'sales_min_price', s.sales_min_price,
        'sales_max_price', s.sales_max_price
      ) order by k.option_key nulls first) options
    from option_keys k
    cross join lateral (
      select count(*) filter (where b.status = 'on_sale') stock_count,
        min(b.price) filter (where b.status = 'on_sale' and b.price > 0) current_price,
        max(b.original_price) filter (where b.original_price > 0) original_price,
        (array_agg(b.price order by b.created_at desc nulls last, b.id desc)
          filter (where b.price > 0 and b.status in ('on_sale', 'reserved', 'settled')))[1] last_recorded_price
      from inventory b where b.option_key is not distinct from k.option_key
    ) i
    cross join lateral (
      select count(*) sales_count, min(s.price) sales_min_price, max(s.price) sales_max_price,
        (array_agg(s.price order by s.sold_at desc nulls last, s.source, s.id desc))[1] last_sold_price,
        (array_agg(s.sold_at order by s.sold_at desc nulls last, s.source, s.id desc))[1] last_sold_at,
        (array_agg(s.condition_grade order by s.sold_at desc nulls last, s.source, s.id desc))[1] last_sold_grade
      from sales s where s.option_key is not distinct from k.option_key
    ) s
  ) agg on true;
  return v_result;
end;
$$;

revoke all on function public.admin_search_products_for_register(text, integer, integer) from public, anon;
grant execute on function public.admin_search_products_for_register(text, integer, integer) to authenticated, service_role;
notify pgrst, 'reload schema';
commit;
