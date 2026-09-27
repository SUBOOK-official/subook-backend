-- PR #22: 추천/테마 CMS, 서버 정렬 및 공개 상품 일괄 조회.
-- 기존 상품·주문 데이터와 RLS는 변경하지 않는다. 신규 콘텐츠는 기본 비노출.
-- 롤백: 프론트를 이전 버전으로 배포하면 기존 목록 RPC와 호환된다.
-- 테이블/운영 콘텐츠는 보존하고 추천·테마 노출만 관리자에서 해제한다.
-- https://supabase.com/docs/guides/database/postgres/row-level-security

create table public.product_recommendations (
  product_id bigint primary key references public.products(id) on delete cascade,
  sort_order integer not null default 100 check (sort_order between 0 and 9999),
  headline text not null default '' check (length(headline) <= 80),
  is_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
create table public.content_themes (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(btrim(title)) between 1 and 20),
  image_url text not null check (image_url ~ '^https://[^[:space:]]+'),
  product_ids bigint[] not null check (cardinality(product_ids) >= 1 and array_position(product_ids, null) is null),
  is_enabled boolean not null default false,
  sort_order integer not null default 100 check (sort_order between 0 and 9999),
  updated_at timestamptz not null default now()
);
alter table public.product_recommendations enable row level security;
alter table public.content_themes enable row level security;
revoke all on public.product_recommendations, public.content_themes from anon, authenticated;
grant select on public.product_recommendations, public.content_themes to anon;
grant select, insert, update, delete on public.product_recommendations, public.content_themes to authenticated;
grant all on public.product_recommendations, public.content_themes to service_role;
create policy recommendations_public_read on public.product_recommendations
  for select to anon, authenticated using (is_enabled);
create policy recommendations_admin_all on public.product_recommendations
  for all to authenticated using ((select public.is_admin_user())) with check ((select public.is_admin_user()));
create policy themes_public_read on public.content_themes
  for select to anon, authenticated using (is_enabled);
create policy themes_admin_all on public.content_themes
  for all to authenticated using ((select public.is_admin_user())) with check ((select public.is_admin_user()));

create function public.touch_curated_content() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;
create trigger recommendations_updated before update on public.product_recommendations
  for each row execute function public.touch_curated_content();
create trigger themes_updated before update on public.content_themes
  for each row execute function public.touch_curated_content();
create index recommendations_display on public.product_recommendations (sort_order, product_id) where is_enabled;
create index themes_display on public.content_themes (sort_order, id) where is_enabled;

-- 현재 목록 함수에서 정렬 부분만 확장한다. 연도(기타)/검색/컬렉션/품절 정책을 보존.
do $migration$
declare
  definition text;
  old_parts text[] := array[
    'coalesce(favorites.favorite_count, 0) as favorite_count',
    'left join favorites on favorites.product_id = ranked_books.product_id',
    'case when params.sort_key = ''relevance'' then scored_products.product_match_score end desc nulls last,',
    'case when params.sort_key = ''popular'' then scored_products.product_popularity_score end desc nulls last,'
  ];
  new_parts text[] := array[
    'coalesce(favorites.favorite_count, 0) as favorite_count, recommendation.sort_order as recommendation_order',
    'left join favorites on favorites.product_id = ranked_books.product_id
    left join public.product_recommendations recommendation on recommendation.product_id = ranked_books.product_id and recommendation.is_enabled',
    'case when params.sort_key = ''recommended'' and scored_products.available_option_count > 0 then scored_products.recommendation_order end asc nulls last,
      case when params.sort_key = ''relevance'' then scored_products.product_match_score end desc nulls last,',
    'case when params.sort_key in (''popular'', ''recommended'') then scored_products.product_popularity_score end desc nulls last,'
  ];
begin
  definition := pg_get_functiondef('public.list_public_store_products(text[],text[],text[],integer[],text[],text,text,integer,integer,text[],text[])'::regprocedure);
  for i in 1..array_length(old_parts, 1) loop
    if (length(definition) - length(replace(definition, old_parts[i], ''))) / length(old_parts[i]) <> 1 then
      raise exception 'Expected exactly one storefront recommendation anchor %; inspect current function', i;
    end if;
    definition := replace(definition, old_parts[i], new_parts[i]);
  end loop;
  execute definition;
end;
$migration$;

-- 내부 공통 조회: 판매 가능한 공개 상품만 카드에 필요한 필드로 반환.
-- 목록용 RPC가 호출하며 API 역할은 이 내부 함수를 직접 실행할 수 없다.
create function public.curated_product_cards(p_product_ids bigint[])
returns table (product_id bigint, display_order bigint, card jsonb)
language sql stable security definer set search_path = public as $$
  with requested as (
    select id, min(ordinality) as display_order
    from unnest(p_product_ids) with ordinality as selected(id, ordinality)
    group by id
  )
  select p.id, requested.display_order, jsonb_build_object(
    'id', p.id, 'product_id', p.id, 'title', p.title, 'option', p.option,
    'subject', p.subject, 'brand', p.brand, 'book_type', p.book_type,
    'published_year', p.published_year, 'instructor_name', p.instructor_name,
    'cover_image_url', coalesce(nullif(b.cover_image_url, ''), p.cover_image_url),
    'condition_grade', b.condition_grade, 'price', b.price, 'original_price', b.original_price,
    'available_option_count', b.available_count, 'available_count', b.available_count,
    'status', 'selling', 'is_public', true, 'created_at', b.created_at
  )
  from requested
  join public.products p on p.id = requested.id and p.is_listed
  join lateral (
    select book.*, count(*) over()::integer as available_count
    from public.books book
    where book.product_id = p.id and book.status = 'on_sale' and book.is_public and book.price is not null
    order by book.price, public.storefront_condition_grade_rank(book.condition_grade), book.created_at desc, book.id desc
    limit 1
  ) b on true;
$$;
revoke all on function public.curated_product_cards(bigint[]) from public, anon, authenticated;

create function public.get_public_recommendation_banners(p_limit integer default 8)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_data order by display_order), '[]'::jsonb)
  from (
    select cards.display_order, jsonb_build_object('headline', r.headline, 'product', cards.card) as row_data
    from public.curated_product_cards(array(
      select product_id from public.product_recommendations where is_enabled order by sort_order, product_id
    )) cards
    join public.product_recommendations r on r.product_id = cards.product_id
    order by cards.display_order
    limit greatest(1, least(coalesce(p_limit, 8), 8))
  ) available;
$$;
revoke all on function public.get_public_recommendation_banners(integer) from public;
grant execute on function public.get_public_recommendation_banners(integer) to anon, authenticated, service_role;

create function public.get_public_theme_page(p_theme_id uuid, p_limit integer default 24, p_offset integer default 0)
returns jsonb language sql stable security definer set search_path = public as $$
  with theme as (
    select * from public.content_themes where id = p_theme_id and is_enabled
  ), cards as materialized (
    select cards.* from theme cross join lateral public.curated_product_cards(theme.product_ids) cards
  ), page as (
    select * from cards order by display_order
    limit greatest(1, least(coalesce(p_limit, 24), 48)) offset greatest(0, coalesce(p_offset, 0))
  )
  select jsonb_build_object(
    'theme', jsonb_build_object('id', theme.id, 'title', theme.title, 'image_url', theme.image_url),
    'products', coalesce((select jsonb_agg(card order by display_order) from page), '[]'::jsonb),
    'total_count', (select count(*) from cards)
  ) from theme;
$$;
revoke all on function public.get_public_theme_page(uuid, integer, integer) from public;
grant execute on function public.get_public_theme_page(uuid, integer, integer) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
