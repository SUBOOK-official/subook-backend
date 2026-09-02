-- 통합 구매 후기 (2026-09-02)
--
-- 배경:
--  - 수북은 1권 = 1행 구조라 상품별 후기는 대부분 0건으로 남는다. 구매자가 실제로
--    불안해하는 건 교재 내용이 아니라 검수 상태·배송·포장이므로, 후기를 서비스 단위로
--    모아 모든 상품 상세에 동일하게 노출한다 (사용자 결정, 2026-09-02).
--  - 작성 단위는 주문 1건당 1개 (품목별 허용 시 같은 사진·문장이 연달아 올라와 통합
--    피드가 도배처럼 보인다). 상품명은 "첫 품목명 외 N권"으로 표시한다.
--  - 작성 조건: 회원 본인 주문 + 구매확정(confirmed). 비회원 주문은 계정이 없어 불가.
--  - 별점 1~5 필수, 본문 10~500자, 사진 최대 3장(선택).
--
-- 기존 public.reviews(2026041303 → 5/19 drop → 6/2 드리프트 복구로 껍데기만 재생성, 0행)는
-- 구조가 품목 단위(order_item_id unique)라 재정의한다. 데이터가 있으면 절대 지우지 않도록
-- 행 수 가드를 둔다.
--
-- 공개 조회는 RPC(get_public_reviews)로만 — 테이블 직접 select는 본인·관리자만 허용해
-- user_id·원문 닉네임이 anon에게 새지 않게 한다. 닉네임 마스킹은 서버(RPC)에서 수행.

begin;

-- 0) 데이터 보호 가드 ---------------------------------------------------------
do $$
declare
  v_count bigint := 0;
begin
  if to_regclass('public.reviews') is not null then
    execute 'select count(*) from public.reviews' into v_count;
    if v_count > 0 then
      raise exception 'public.reviews에 데이터가 % 건 있어 재정의를 중단합니다. 수동 확인 필요.', v_count;
    end if;
  end if;
end $$;

-- 1) 레거시 객체 정리 ---------------------------------------------------------
drop function if exists public.create_product_review(bigint, integer, text, text[]);
drop function if exists public.get_public_product_reviews(bigint, text, integer, integer);
drop trigger if exists reviews_set_updated_at on public.reviews;
drop table if exists public.reviews cascade;

-- 2) 테이블 --------------------------------------------------------------------
create table public.reviews (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  order_id bigint not null references public.orders(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  content text not null check (char_length(btrim(content)) between 10 and 500),
  photo_urls text[] not null default '{}'::text[]
    check (coalesce(cardinality(photo_urls), 0) <= 3),
  -- 주문에 담긴 상품 id 스냅샷 — 상세페이지에서 "같은 상품 후기 먼저" 정렬용
  product_ids bigint[] not null default '{}'::bigint[],
  primary_product_id bigint references public.products(id) on delete set null,
  primary_title text not null,
  -- 환불되지 않은 품목의 총 권수 (표시: "primary_title 외 N권")
  item_count integer not null default 1 check (item_count >= 1),
  is_hidden boolean not null default false,
  hidden_reason text,
  hidden_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_id)
);

comment on table public.reviews is '통합 구매 후기 — 주문 1건당 1개, 모든 상품 상세에 공통 노출 (2026-09-02)';

create index idx_reviews_visible_created_at
  on public.reviews (created_at desc, id desc)
  where is_hidden = false;
create index idx_reviews_user_id on public.reviews (user_id);
create index idx_reviews_product_ids on public.reviews using gin (product_ids);

alter table public.reviews enable row level security;

-- 본인 행만 직접 조회 가능(디버깅·마이페이지 폴백용). 공개 노출은 RPC 경유.
drop policy if exists "reviews_select_own" on public.reviews;
create policy "reviews_select_own" on public.reviews
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "reviews_admin_all" on public.reviews;
create policy "reviews_admin_all" on public.reviews
  for all to authenticated
  using (public.is_admin_user()) with check (public.is_admin_user());

create or replace function public.touch_reviews_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger reviews_set_updated_at
before update on public.reviews
for each row execute function public.touch_reviews_updated_at();

-- 3) 닉네임 마스킹 --------------------------------------------------------------
-- 앞 2글자(2글자 이하면 1글자)만 남기고 나머지는 *(최대 4개). 빈 값이면 '수북회원'.
create or replace function public.mask_review_nickname(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when v is null then '수북회원'
    when char_length(v) <= 2 then left(v, 1) || '*'
    else left(v, 2) || repeat('*', least(char_length(v) - 2, 4))
  end
  from (select nullif(btrim(coalesce(p_name, '')), '') as v) s;
$$;

-- 4) 공개 조회 -----------------------------------------------------------------
-- p_product_id를 주면 그 상품이 포함된 주문의 후기를 맨 위로 올린다(나머지는 최신순).
-- total/average/rating_counts는 전체(통합) 기준, same_product_count는 해당 상품 기준.
create or replace function public.get_public_reviews(
  p_product_id bigint default null,
  p_limit integer default 10,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total bigint;
  v_average numeric;
  v_counts jsonb;
  v_same_count bigint := 0;
  v_items jsonb;
begin
  select count(*), round(avg(rating)::numeric, 1)
  into v_total, v_average
  from public.reviews
  where is_hidden = false;

  select coalesce(jsonb_object_agg(rating::text, cnt), '{}'::jsonb)
  into v_counts
  from (
    select rating, count(*) as cnt
    from public.reviews
    where is_hidden = false
    group by rating
  ) c;

  if p_product_id is not null then
    select count(*) into v_same_count
    from public.reviews
    where is_hidden = false
      and product_ids @> array[p_product_id];
  end if;

  select coalesce(jsonb_agg(row_data), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', r.id,
      'author', public.mask_review_nickname(coalesce(mp.nickname, mp.name)),
      'rating', r.rating,
      'content', r.content,
      'photo_urls', to_jsonb(r.photo_urls),
      'product_id', r.primary_product_id,
      'product_title', r.primary_title,
      'item_count', r.item_count,
      'is_same_product', (p_product_id is not null and r.product_ids @> array[p_product_id]),
      'created_at', r.created_at
    ) as row_data
    from public.reviews r
    left join public.member_profiles mp on mp.user_id = r.user_id
    where r.is_hidden = false
    order by
      (p_product_id is not null and r.product_ids @> array[p_product_id]) desc,
      r.created_at desc,
      r.id desc
    limit v_limit offset v_offset
  ) sub;

  return jsonb_build_object(
    'total', coalesce(v_total, 0),
    'average', v_average,
    'rating_counts', v_counts,
    'same_product_count', v_same_count,
    'items', v_items
  );
end;
$$;

grant execute on function public.get_public_reviews(bigint, integer, integer) to anon, authenticated;

-- 5) 회원 본인 후기 조회 (마이페이지 — 주문별 작성/수정 버튼 분기용) ---------------
create or replace function public.get_my_reviews()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id,
      'order_id', r.order_id,
      'rating', r.rating,
      'content', r.content,
      'photo_urls', to_jsonb(r.photo_urls),
      'product_title', r.primary_title,
      'item_count', r.item_count,
      'is_hidden', r.is_hidden,
      'created_at', r.created_at,
      'updated_at', r.updated_at
    ) order by r.created_at desc)
    from public.reviews r
    where r.user_id = v_user_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.get_my_reviews() from public;
revoke all on function public.get_my_reviews() from anon;
grant execute on function public.get_my_reviews() to authenticated;

-- 6) 입력 정규화 공용 헬퍼 (create/update 공유) ----------------------------------
-- 사진 URL은 본인 폴더(review-images/<uid>/...)의 public URL만 허용 — 타인 사진·외부 URL 차단.
create or replace function public.normalize_review_input(
  p_user_id uuid,
  p_rating integer,
  p_content text,
  p_photo_urls text[]
)
returns table (rating integer, content text, photo_urls text[])
language plpgsql
immutable
set search_path = public
as $$
declare
  v_content text;
  v_photos text[];
  v_prefix text := '/storage/v1/object/public/review-images/' || p_user_id::text || '/';
  v_url text;
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception '별점은 1점부터 5점까지 선택해 주세요.';
  end if;

  v_content := btrim(coalesce(p_content, ''));
  if char_length(v_content) < 10 then
    raise exception '후기는 10자 이상 작성해 주세요.';
  end if;
  if char_length(v_content) > 500 then
    raise exception '후기는 500자까지 작성할 수 있어요.';
  end if;

  select coalesce(array_agg(u order by ord), '{}'::text[])
  into v_photos
  from (
    select nullif(btrim(photo_url), '') as u, ordinality as ord
    from unnest(coalesce(p_photo_urls, '{}'::text[])) with ordinality as photo(photo_url, ordinality)
  ) s
  where u is not null;

  if coalesce(cardinality(v_photos), 0) > 3 then
    raise exception '사진은 최대 3장까지 첨부할 수 있어요.';
  end if;

  foreach v_url in array v_photos loop
    if position(v_prefix in v_url) = 0 or v_url !~ '^https://' then
      raise exception '허용되지 않은 사진 경로가 포함되어 있어요.';
    end if;
  end loop;

  rating := p_rating;
  content := v_content;
  photo_urls := v_photos;
  return next;
end;
$$;

revoke all on function public.normalize_review_input(uuid, integer, text, text[]) from public;
revoke all on function public.normalize_review_input(uuid, integer, text, text[]) from anon;
revoke all on function public.normalize_review_input(uuid, integer, text, text[]) from authenticated;

-- 7) 작성 -----------------------------------------------------------------------
create or replace function public.create_review(
  p_order_id bigint,
  p_rating integer,
  p_content text,
  p_photo_urls text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order record;
  v_items record;
  v_input record;
  v_review public.reviews%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  perform public.assert_member_not_blocked();

  select o.id, o.status
  into v_order
  from public.orders o
  where o.id = p_order_id
    and o.user_id = v_user_id
  limit 1;

  if not found then
    raise exception '주문을 찾을 수 없어요.';
  end if;
  if v_order.status <> 'confirmed' then
    raise exception '구매확정 후에 후기를 작성할 수 있어요.';
  end if;
  if exists (select 1 from public.reviews r where r.order_id = p_order_id) then
    raise exception '이미 후기를 작성한 주문이에요.';
  end if;

  select * into v_input
  from public.normalize_review_input(v_user_id, p_rating, p_content, p_photo_urls);

  -- 환불되지 않은 품목만 후기 대상. 첫 품목명(id 오름차순)을 대표 제목으로.
  select
    (array_agg(oi.title order by oi.id))[1] as primary_title,
    (array_agg(oi.product_id order by oi.id) filter (where oi.product_id is not null))[1] as primary_product_id,
    coalesce(array_agg(distinct oi.product_id) filter (where oi.product_id is not null), '{}'::bigint[]) as product_ids,
    coalesce(sum(greatest(coalesce(oi.quantity, 1), 1)), 0)::integer as item_count
  into v_items
  from public.order_items oi
  where oi.order_id = p_order_id
    and oi.refunded_at is null;

  if v_items.item_count is null or v_items.item_count < 1 or v_items.primary_title is null then
    raise exception '환불된 주문에는 후기를 남길 수 없어요.';
  end if;

  insert into public.reviews (
    user_id, order_id, rating, content, photo_urls,
    product_ids, primary_product_id, primary_title, item_count
  ) values (
    v_user_id, p_order_id, v_input.rating, v_input.content, v_input.photo_urls,
    v_items.product_ids, v_items.primary_product_id, v_items.primary_title, v_items.item_count
  )
  returning * into v_review;

  return jsonb_build_object(
    'id', v_review.id,
    'order_id', v_review.order_id,
    'rating', v_review.rating,
    'content', v_review.content,
    'photo_urls', to_jsonb(v_review.photo_urls),
    'product_title', v_review.primary_title,
    'item_count', v_review.item_count,
    'is_hidden', v_review.is_hidden,
    'created_at', v_review.created_at,
    'updated_at', v_review.updated_at
  );
end;
$$;

revoke all on function public.create_review(bigint, integer, text, text[]) from public;
revoke all on function public.create_review(bigint, integer, text, text[]) from anon;
grant execute on function public.create_review(bigint, integer, text, text[]) to authenticated;

-- 8) 수정 -----------------------------------------------------------------------
create or replace function public.update_review(
  p_review_id bigint,
  p_rating integer,
  p_content text,
  p_photo_urls text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_input record;
  v_review public.reviews%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  perform public.assert_member_not_blocked();

  if not exists (
    select 1 from public.reviews r where r.id = p_review_id and r.user_id = v_user_id
  ) then
    raise exception '후기를 찾을 수 없어요.';
  end if;

  select * into v_input
  from public.normalize_review_input(v_user_id, p_rating, p_content, p_photo_urls);

  update public.reviews
  set rating = v_input.rating,
      content = v_input.content,
      photo_urls = v_input.photo_urls
  where id = p_review_id
    and user_id = v_user_id
  returning * into v_review;

  return jsonb_build_object(
    'id', v_review.id,
    'order_id', v_review.order_id,
    'rating', v_review.rating,
    'content', v_review.content,
    'photo_urls', to_jsonb(v_review.photo_urls),
    'product_title', v_review.primary_title,
    'item_count', v_review.item_count,
    'is_hidden', v_review.is_hidden,
    'created_at', v_review.created_at,
    'updated_at', v_review.updated_at
  );
end;
$$;

revoke all on function public.update_review(bigint, integer, text, text[]) from public;
revoke all on function public.update_review(bigint, integer, text, text[]) from anon;
grant execute on function public.update_review(bigint, integer, text, text[]) to authenticated;

-- 9) 삭제 (본인) — 스토리지 사진은 클라이언트가 본인 폴더 정책으로 정리 -------------
create or replace function public.delete_review(p_review_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_deleted integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  delete from public.reviews
  where id = p_review_id
    and user_id = v_user_id;
  get diagnostics v_deleted = row_count;

  if v_deleted = 0 then
    raise exception '후기를 찾을 수 없어요.';
  end if;
  return true;
end;
$$;

revoke all on function public.delete_review(bigint) from public;
revoke all on function public.delete_review(bigint) from anon;
grant execute on function public.delete_review(bigint) to authenticated;

-- 10) 어드민 — 목록(마스킹 없음) + 숨김 토글 ---------------------------------------
create or replace function public.admin_list_reviews(
  p_filter text default 'all',      -- all | visible | hidden
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_filter text := coalesce(p_filter, 'all');
  v_total bigint;
  v_items jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select count(*) into v_total
  from public.reviews r
  where (v_filter = 'all')
     or (v_filter = 'visible' and r.is_hidden = false)
     or (v_filter = 'hidden' and r.is_hidden = true);

  select coalesce(jsonb_agg(row_data), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', r.id,
      'user_id', r.user_id,
      'nickname', mp.nickname,
      'member_name', mp.name,
      'member_email', mp.email,
      'order_id', r.order_id,
      'order_number', o.order_number,
      'rating', r.rating,
      'content', r.content,
      'photo_urls', to_jsonb(r.photo_urls),
      'product_id', r.primary_product_id,
      'product_title', r.primary_title,
      'item_count', r.item_count,
      'is_hidden', r.is_hidden,
      'hidden_reason', r.hidden_reason,
      'hidden_at', r.hidden_at,
      'created_at', r.created_at,
      'updated_at', r.updated_at
    ) as row_data
    from public.reviews r
    left join public.member_profiles mp on mp.user_id = r.user_id
    left join public.orders o on o.id = r.order_id
    where (v_filter = 'all')
       or (v_filter = 'visible' and r.is_hidden = false)
       or (v_filter = 'hidden' and r.is_hidden = true)
    order by r.created_at desc, r.id desc
    limit v_limit offset v_offset
  ) sub;

  return jsonb_build_object('total', coalesce(v_total, 0), 'items', v_items);
end;
$$;

revoke all on function public.admin_list_reviews(text, integer, integer) from public;
revoke all on function public.admin_list_reviews(text, integer, integer) from anon;
grant execute on function public.admin_list_reviews(text, integer, integer) to authenticated;

create or replace function public.admin_set_review_hidden(
  p_review_id bigint,
  p_hidden boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review public.reviews%rowtype;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  update public.reviews
  set is_hidden = coalesce(p_hidden, false),
      hidden_reason = case when coalesce(p_hidden, false) then nullif(btrim(coalesce(p_reason, '')), '') else null end,
      hidden_at = case when coalesce(p_hidden, false) then now() else null end
  where id = p_review_id
  returning * into v_review;

  if v_review.id is null then
    raise exception '후기를 찾을 수 없습니다. (id=%)', p_review_id;
  end if;

  return jsonb_build_object(
    'id', v_review.id,
    'is_hidden', v_review.is_hidden,
    'hidden_reason', v_review.hidden_reason,
    'hidden_at', v_review.hidden_at
  );
end;
$$;

revoke all on function public.admin_set_review_hidden(bigint, boolean, text) from public;
revoke all on function public.admin_set_review_hidden(bigint, boolean, text) from anon;
grant execute on function public.admin_set_review_hidden(bigint, boolean, text) to authenticated;

-- 11) 스토리지 버킷 review-images ----------------------------------------------
-- 경로 규약: <user_id>/<order_id>/<timestamp>-<n>.jpg — 본인 폴더에만 쓰기/삭제 가능.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'review-images',
  'review-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "review-images public read" on storage.objects;
create policy "review-images public read"
  on storage.objects for select
  using (bucket_id = 'review-images');

drop policy if exists "review-images owner insert" on storage.objects;
create policy "review-images owner insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'review-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "review-images owner delete" on storage.objects;
create policy "review-images owner delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'review-images'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin_user()
    )
  );

commit;

-- PostgREST 스키마 캐시 리로드 (pooler 경유 시 미도달 가능 → 대시보드 Reload 권장)
notify pgrst, 'reload schema';
