-- search_storefront_products RPC를 product + first available book 정보까지 함께 반환하도록 강화
-- (가격, condition_grade, available_count 포함 — storefront 카드 표시용)

begin;

drop function if exists public.search_storefront_products(text, integer, integer);

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
        case when v_is_chosung_only then similarity(p.search_chosung, v_q_chosung) else 0 end,
        case when position(v_q in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
      )::real as match_score
    from public.products p
    where p.status <> 'hidden'
      and (
        p.search_text ilike '%' || v_q || '%'
        or (v_is_chosung_only and p.search_chosung ilike '%' || v_q_chosung || '%')
        or similarity(p.search_text, v_q) > 0.15
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

grant execute on function public.search_storefront_products(text, integer, integer) to anon, authenticated;

commit;
