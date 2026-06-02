-- DRIFT REPAIR: wishlist_items 테이블/함수 재생성.
--
-- 배경: 2026041304_add_member_wishlist.sql 는 schema_migrations 상 applied로 기록돼 있으나
--   (2026-05-04 드리프트 정리 때 '실행 없이 applied로 back-mark'된 버전 중 하나),
--   실제 prod에는 public.wishlist_items 테이블과 get_my_wishlist_products 함수가 없다.
--   (PostgREST: PGRST205 wishlist_items 없음 / PGRST202 get_my_wishlist_products 없음)
--   → 로그인 사용자 찜 조회/저장이 404로 실패. 이를 보정한다.
--
-- 범위: wishlist_items(테이블·인덱스·RLS·정책) + get_my_wishlist_products 함수만 재생성.
--   get_public_store_product_detail 은 prod에 이미 존재하고(2026040710 버전), 반환 시그니처가
--   2026041304 버전과 동일(25컬럼)하므로 건드리지 않는다(불필요한 위험 회피).
-- 전부 멱등(IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS) — 비파괴적.

create table if not exists public.wishlist_items (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now()
);

create unique index if not exists idx_wishlist_items_user_product
  on public.wishlist_items (user_id, product_id);

create index if not exists idx_wishlist_items_user_created_at
  on public.wishlist_items (user_id, created_at desc, id desc);

create index if not exists idx_wishlist_items_product_id
  on public.wishlist_items (product_id);

alter table public.wishlist_items enable row level security;

drop policy if exists wishlist_items_select_self on public.wishlist_items;
drop policy if exists wishlist_items_insert_self on public.wishlist_items;
drop policy if exists wishlist_items_delete_self on public.wishlist_items;

create policy wishlist_items_select_self
  on public.wishlist_items
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy wishlist_items_insert_self
  on public.wishlist_items
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy wishlist_items_delete_self
  on public.wishlist_items
  for delete
  to authenticated
  using (auth.uid() = user_id);

create or replace function public.get_my_wishlist_products(
  p_limit integer default 24,
  p_offset integer default 0
)
returns table (
  wishlisted_at timestamptz,
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
  related_books jsonb,
  option_books jsonb,
  available_option_count integer,
  sold_out_option_count integer,
  total_option_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    wi.created_at as wishlisted_at,
    detail.id,
    detail.product_id,
    detail.title,
    detail.option,
    detail.subject,
    detail.brand,
    detail.book_type,
    detail.published_year,
    detail.instructor_name,
    detail.condition_grade,
    detail.price,
    detail.original_price,
    detail.discount_rate,
    detail.cover_image_url,
    detail.inspection_image_urls,
    detail.writing_percentage,
    detail.has_damage,
    detail.inspection_notes,
    detail.inspected_at,
    detail.created_at,
    detail.related_books,
    detail.option_books,
    detail.available_option_count,
    detail.sold_out_option_count,
    detail.total_option_count
  from public.wishlist_items wi
  cross join lateral public.get_public_store_product_detail(wi.product_id) detail
  where wi.user_id = auth.uid()
  order by wi.created_at desc, wi.id desc
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 24), 200));
$$;

grant execute on function public.get_my_wishlist_products(integer, integer) to authenticated;
