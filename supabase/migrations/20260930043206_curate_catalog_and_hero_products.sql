-- 추천순은 공개 목록에 포함되는 품절 교재에도 적용한다. 공개/재고 정책은 그대로 둔다.
-- 배너는 추천순과 독립적으로 운영한다. 현재 노출 중인 자동 배너를 최초 1회 복사한다.
-- 롤백: 이전 프런트를 복원하고 추천순 함수의 아래 두 정렬식을 이전 식으로 되돌린다.
-- 새 테이블/함수는 데이터 보존을 위해 남겨도 기존 클라이언트에 영향을 주지 않는다.
create table public.product_hero_banners (
  product_id bigint primary key references public.products(id) on delete cascade,
  sort_order integer not null default 100 check (sort_order between 0 and 9999),
  headline text not null default '' check (length(headline) <= 20),
  is_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.product_hero_banners enable row level security;
revoke all on public.product_hero_banners from public, anon, authenticated;
grant select on public.product_hero_banners to anon;
grant select, insert, update, delete on public.product_hero_banners to authenticated;
grant all on public.product_hero_banners to service_role;
create policy hero_banners_public_read on public.product_hero_banners
  for select to anon, authenticated using (is_enabled);
create policy hero_banners_admin_all on public.product_hero_banners
  for all to authenticated using ((select public.is_admin_user())) with check ((select public.is_admin_user()));
create trigger hero_banners_updated before update on public.product_hero_banners
  for each row execute function public.touch_curated_content();
create index hero_banners_display on public.product_hero_banners(sort_order, product_id) where is_enabled;

insert into public.product_hero_banners(product_id,sort_order,is_enabled)
select id, (ordinality - 1)::integer * 10, true
from public.list_public_store_products(p_sort=>'recommended',p_limit=>(
  select (ceil((count(*)+8)::numeric/6)*6-count(*))::integer
  from public.site_promotions where placement='home_hero' and is_enabled
    and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>now())
),p_offset=>0) with ordinality;

do $migration$
declare
  definition text;
  old_part text := 'case when params.sort_key = ''recommended'' and scored_products.available_option_count > 0 then scored_products.recommendation_order end asc nulls last,';
  new_part text := 'case when params.sort_key = ''recommended'' then scored_products.recommendation_order end asc nulls last,
      case when params.sort_key = ''recommended'' and scored_products.recommendation_order is not null then scored_products.product_id end asc nulls last,';
begin
  definition := pg_get_functiondef('public.list_public_store_products(text[],text[],text[],integer[],text[],text,text,integer,integer,text[],text[])'::regprocedure);
  if (length(definition) - length(replace(definition, old_part, ''))) / length(old_part) <> 1 then
    raise exception 'Expected one recommendation sort anchor; inspect current function';
  end if;
  execute replace(definition, old_part, new_part);
end;
$migration$;

-- 검색어가 없으면 전체 상품, 공백으로 나눈 검색어는 교재명/옵션/강사/브랜드/과목 등에 모두 적용.
-- 관리자는 숨김·품절 교재도 등록할 수 있다. 고객 노출 여부는 공개 RPC가 판단한다.
create function public.admin_list_curated_products(p_search text default '', p_limit integer default 30, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if public.is_admin_user() is not true then raise insufficient_privilege using message = '관리자 권한이 필요합니다.'; end if;
  return (
    with matches as materialized (
      select p.id,p.title,p.option,p.cover_image_url,p.subject,p.brand,p.book_type,p.instructor_name,p.published_year,p.status,p.is_listed
      from public.products p
      where not exists (
        select 1 from regexp_split_to_table(lower(btrim(coalesce(p_search,''))), '[[:space:]]+') token
        where token <> '' and strpos(
          regexp_replace(lower(concat_ws(' ',p.id,p.title,p.option,p.subject,p.brand,p.book_type,p.instructor_name,p.published_year)), '[[:space:]]+', '', 'g'),
          token
        ) = 0
      )
    ), page as (
      select * from matches order by id desc
      limit greatest(1,least(coalesce(p_limit,30),100)) offset greatest(0,coalesce(p_offset,0))
    )
    select jsonb_build_object('products',coalesce((select jsonb_agg(page order by id desc) from page),'[]'::jsonb),
      'total_count',(select count(*) from matches))
  );
end;
$$;
revoke all on function public.admin_list_curated_products(text,integer,integer) from public, anon;
grant execute on function public.admin_list_curated_products(text,integer,integer) to authenticated;

-- 기존 상세 RPC의 공개 조건과 품절 판정을 재사용한다. 등록하지 않은 교재를 자동으로 채우지 않는다.
create function public.get_public_hero_products()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('headline',h.headline,
    'product',to_jsonb(d) - 'related_books' - 'option_books') order by h.sort_order,h.product_id),'[]'::jsonb)
  from public.product_hero_banners h
  cross join lateral public.get_public_store_product_detail(h.product_id) d
  where h.is_enabled;
$$;
revoke all on function public.get_public_hero_products() from public;
grant execute on function public.get_public_hero_products() to anon, authenticated, service_role;

-- AI 문구도 실제 배너 목록에 맞춰 생성한다. 수동 문구가 있으면 AI 생성 대상에서 제외한다.
create or replace function public.get_banner_copy_sources()
returns table(id bigint,title text,subject text,brand text,book_type text,ai_summary text,source_hash text)
language sql stable security definer set search_path = '' as $$
  select p.id,p.title::text,p.subject::text,p.brand::text,p.book_type::text,p.ai_summary,
    public.banner_copy_source_hash(p)
  from jsonb_array_elements(public.get_public_hero_products()) r
  join public.products p on p.id=(r->'product'->>'id')::bigint
  left join public.banner_copy_cache c on c.product_id=p.id
  where btrim(coalesce(r->>'headline',''))=''
  -- 한 실행 13개 제한에서도 이미 생성된 앞쪽 교재가 뒤쪽 교재를 영구히 막지 않도록 한다.
  order by (c.copy is not null and c.source_hash=public.banner_copy_source_hash(p)),
    coalesce(c.next_attempt_at,'-infinity'::timestamptz),p.id;
$$;

notify pgrst, 'reload schema';
