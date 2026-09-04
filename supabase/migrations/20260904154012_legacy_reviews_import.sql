-- 식스샵 시절 실구매 후기를 신규 주문 데이터와 분리해 이관한다.
--
-- 가짜 orders/order_items를 만들면 매출·정산·판매량 통계와 운영 알림이 오염될 수 있으므로
-- legacy_reviews를 별도 원장으로 두고 공개/어드민 조회 RPC에서만 통합한다.
-- source_key는 동일 배치 재실행 시 후기와 포인트가 중복 등록되는 것을 막는다.

begin;

create table if not exists public.legacy_reviews (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null default 'sixshop' check (source in ('sixshop')),
  source_key text not null unique,
  rating integer not null check (rating between 1 and 5),
  content text not null check (char_length(btrim(content)) between 10 and 500),
  photo_urls text[] not null default '{}'::text[]
    check (coalesce(cardinality(photo_urls), 0) <= 3),
  product_ids bigint[] not null check (coalesce(cardinality(product_ids), 0) >= 1),
  primary_product_id bigint references public.products(id) on delete set null,
  primary_title text not null,
  item_count integer not null default 1 check (item_count >= 1),
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  is_hidden boolean not null default false,
  hidden_reason text,
  hidden_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.legacy_reviews is
  '식스샵 실구매 후기 이관 원장 — 신규 주문/매출/정산 데이터와 분리해 통합 후기 RPC에서만 함께 노출';

create index if not exists idx_legacy_reviews_visible_created_at
  on public.legacy_reviews (created_at desc, id desc)
  where is_hidden = false;
create index if not exists idx_legacy_reviews_user_id
  on public.legacy_reviews (user_id);
create index if not exists idx_legacy_reviews_product_ids
  on public.legacy_reviews using gin (product_ids);

alter table public.legacy_reviews enable row level security;

drop policy if exists "legacy_reviews_admin_all" on public.legacy_reviews;
create policy "legacy_reviews_admin_all"
  on public.legacy_reviews
  for all
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop trigger if exists legacy_reviews_set_updated_at on public.legacy_reviews;
create trigger legacy_reviews_set_updated_at
before update on public.legacy_reviews
for each row execute function public.touch_reviews_updated_at();

-- 공개 후기 조회: 신규 주문 후기와 식스샵 이전 후기를 같은 목록으로 합친다.
-- 공개 id는 기존 후기 양수, 식스샵 후기 음수로 구분해 프런트 숫자 id 계약과 key 유일성을 지킨다.
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
  select count(*), round(avg(s.rating)::numeric, 1)
  into v_total, v_average
  from (
    select r.rating from public.reviews r where r.is_hidden = false
    union all
    select lr.rating from public.legacy_reviews lr where lr.is_hidden = false
  ) s;

  select coalesce(jsonb_object_agg(s.rating::text, s.cnt), '{}'::jsonb)
  into v_counts
  from (
    select ratings.rating, count(*) as cnt
    from (
      select r.rating from public.reviews r where r.is_hidden = false
      union all
      select lr.rating from public.legacy_reviews lr where lr.is_hidden = false
    ) ratings
    group by ratings.rating
  ) s;

  if p_product_id is not null then
    select count(*) into v_same_count
    from (
      select r.product_ids from public.reviews r where r.is_hidden = false
      union all
      select lr.product_ids from public.legacy_reviews lr where lr.is_hidden = false
    ) s
    where s.product_ids @> array[p_product_id];
  end if;

  select coalesce(
    jsonb_agg(
      page.row_data
      order by page.is_same_product desc, page.created_at desc, page.public_id desc
    ),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      src.public_id,
      src.created_at,
      (p_product_id is not null and src.product_ids @> array[p_product_id]) as is_same_product,
      jsonb_build_object(
        'id', src.public_id,
        'source', src.source,
        'author', public.mask_review_nickname(coalesce(mp.nickname, mp.name)),
        'rating', src.rating,
        'content', src.content,
        'photo_urls', to_jsonb(src.photo_urls),
        'product_id', src.primary_product_id,
        'product_title', src.primary_title,
        'item_count', src.item_count,
        'is_same_product', (p_product_id is not null and src.product_ids @> array[p_product_id]),
        'created_at', src.created_at,
        'items', src.items
      ) as row_data
    from (
      select
        r.id as public_id,
        'subook'::text as source,
        r.user_id,
        r.rating,
        r.content,
        r.photo_urls,
        r.product_ids,
        r.primary_product_id,
        r.primary_title,
        r.item_count,
        r.created_at,
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'product_id', grouped.product_id,
            'title', grouped.title,
            'cover_image_url', grouped.cover_image_url,
            'quantity', grouped.quantity
          ) order by grouped.first_id)
          from (
            select
              oi.product_id,
              min(oi.title) as title,
              min(oi.cover_image_url) as cover_image_url,
              sum(greatest(coalesce(oi.quantity, 1), 1))::integer as quantity,
              min(oi.id) as first_id
            from public.order_items oi
            where oi.order_id = r.order_id
              and oi.refunded_at is null
            group by oi.product_id, oi.title
          ) grouped
        ), '[]'::jsonb) as items
      from public.reviews r
      where r.is_hidden = false

      union all

      select
        -lr.id as public_id,
        lr.source,
        lr.user_id,
        lr.rating,
        lr.content,
        lr.photo_urls,
        lr.product_ids,
        lr.primary_product_id,
        lr.primary_title,
        lr.item_count,
        lr.created_at,
        lr.items
      from public.legacy_reviews lr
      where lr.is_hidden = false
    ) src
    left join public.member_profiles mp on mp.user_id = src.user_id
    order by
      (p_product_id is not null and src.product_ids @> array[p_product_id]) desc,
      src.created_at desc,
      src.public_id desc
    limit v_limit offset v_offset
  ) page;

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

-- 어드민 목록도 두 원장을 합친다. legacy id는 음수로 반환해 숨김 RPC 라우팅에 사용한다.
create or replace function public.admin_list_reviews(
  p_filter text default 'all',
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
  from (
    select r.is_hidden from public.reviews r
    union all
    select lr.is_hidden from public.legacy_reviews lr
  ) src
  where (v_filter = 'all')
     or (v_filter = 'visible' and src.is_hidden = false)
     or (v_filter = 'hidden' and src.is_hidden = true);

  select coalesce(jsonb_agg(page.row_data order by page.created_at desc, page.public_id desc), '[]'::jsonb)
  into v_items
  from (
    select
      src.public_id,
      src.created_at,
      jsonb_build_object(
        'id', src.public_id,
        'source', src.source,
        'user_id', src.user_id,
        'nickname', mp.nickname,
        'member_name', mp.name,
        'member_email', mp.email,
        'order_id', src.order_id,
        'order_number', src.order_number,
        'rating', src.rating,
        'content', src.content,
        'photo_urls', to_jsonb(src.photo_urls),
        'product_id', src.primary_product_id,
        'product_title', src.primary_title,
        'item_count', src.item_count,
        'is_hidden', src.is_hidden,
        'hidden_reason', src.hidden_reason,
        'hidden_at', src.hidden_at,
        'created_at', src.created_at,
        'updated_at', src.updated_at
      ) as row_data
    from (
      select
        r.id as public_id,
        'subook'::text as source,
        r.user_id,
        r.order_id,
        o.order_number,
        r.rating,
        r.content,
        r.photo_urls,
        r.primary_product_id,
        r.primary_title,
        r.item_count,
        r.is_hidden,
        r.hidden_reason,
        r.hidden_at,
        r.created_at,
        r.updated_at
      from public.reviews r
      left join public.orders o on o.id = r.order_id

      union all

      select
        -lr.id as public_id,
        lr.source,
        lr.user_id,
        null::bigint as order_id,
        null::text as order_number,
        lr.rating,
        lr.content,
        lr.photo_urls,
        lr.primary_product_id,
        lr.primary_title,
        lr.item_count,
        lr.is_hidden,
        lr.hidden_reason,
        lr.hidden_at,
        lr.created_at,
        lr.updated_at
      from public.legacy_reviews lr
    ) src
    left join public.member_profiles mp on mp.user_id = src.user_id
    where (v_filter = 'all')
       or (v_filter = 'visible' and src.is_hidden = false)
       or (v_filter = 'hidden' and src.is_hidden = true)
    order by src.created_at desc, src.public_id desc
    limit v_limit offset v_offset
  ) page;

  return jsonb_build_object('total', coalesce(v_total, 0), 'items', v_items);
end;
$$;

revoke all on function public.admin_list_reviews(text, integer, integer) from public;
revoke all on function public.admin_list_reviews(text, integer, integer) from anon;
grant execute on function public.admin_list_reviews(text, integer, integer) to authenticated;

-- 음수 id는 legacy_reviews, 양수 id는 기존 reviews를 숨긴다.
-- 기존 주문 후기 숨김 시 후기 적립 포인트 회수 동작은 그대로 유지한다.
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
  v_legacy_review public.legacy_reviews%rowtype;
  v_reclaimed integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_review_id < 0 then
    update public.legacy_reviews
    set is_hidden = coalesce(p_hidden, false),
        hidden_reason = case when coalesce(p_hidden, false) then nullif(btrim(coalesce(p_reason, '')), '') else null end,
        hidden_at = case when coalesce(p_hidden, false) then now() else null end
    where id = -p_review_id
    returning * into v_legacy_review;

    if v_legacy_review.id is null then
      raise exception '후기를 찾을 수 없습니다. (id=%)', p_review_id;
    end if;

    return jsonb_build_object(
      'id', p_review_id,
      'is_hidden', v_legacy_review.is_hidden,
      'hidden_reason', v_legacy_review.hidden_reason,
      'hidden_at', v_legacy_review.hidden_at,
      'reclaimed_points', 0
    );
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

  if coalesce(p_hidden, false) then
    v_reclaimed := public.reclaim_review_points(p_review_id, '후기 숨김 처리');
  end if;

  return jsonb_build_object(
    'id', v_review.id,
    'is_hidden', v_review.is_hidden,
    'hidden_reason', v_review.hidden_reason,
    'hidden_at', v_review.hidden_at,
    'reclaimed_points', v_reclaimed
  );
end;
$$;

revoke all on function public.admin_set_review_hidden(bigint, boolean, text) from public;
revoke all on function public.admin_set_review_hidden(bigint, boolean, text) from anon;
grant execute on function public.admin_set_review_hidden(bigint, boolean, text) to authenticated;

-- 운영용 식스샵 후기 이관 RPC. 이메일/상품 매칭을 검증하고 후기 등록과 선택적 포인트 지급을
-- 한 트랜잭션에서 처리한다. source_key 충돌 시 아무 것도 다시 지급하지 않는다.
create or replace function public.admin_import_legacy_review(
  p_member_email text,
  p_product_ids bigint[],
  p_rating integer,
  p_content text,
  p_created_at timestamptz default null,
  p_points integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(coalesce(p_member_email, '')));
  v_content text := btrim(coalesce(p_content, ''));
  v_product_ids bigint[];
  v_member record;
  v_member_count integer;
  v_product_count integer;
  v_primary_product record;
  v_items jsonb;
  v_source_key text;
  v_existing_id bigint;
  v_review_id bigint;
  v_created_at timestamptz := coalesce(p_created_at, now());
begin
  if not public.is_admin_user() and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Admin access required';
  end if;
  if v_email = '' then
    raise exception '회원 이메일이 필요합니다.';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception '별점은 1~5점이어야 합니다.';
  end if;
  if char_length(v_content) < 10 or char_length(v_content) > 500 then
    raise exception '후기는 10~500자여야 합니다.';
  end if;
  if coalesce(p_points, 0) < 0 or coalesce(p_points, 0) > 100000 then
    raise exception '포인트는 0~100,000P 범위여야 합니다.';
  end if;

  select array_agg(d.product_id order by d.first_ordinality)
  into v_product_ids
  from (
    select input.product_id, min(input.ordinality) as first_ordinality
    from unnest(coalesce(p_product_ids, '{}'::bigint[])) with ordinality as input(product_id, ordinality)
    where input.product_id is not null
    group by input.product_id
  ) d;

  if coalesce(cardinality(v_product_ids), 0) = 0 then
    raise exception '연결할 상품이 1개 이상 필요합니다.';
  end if;

  select count(*)::integer into v_member_count
  from public.member_profiles mp
  where lower(mp.email) = v_email;

  if v_member_count <> 1 then
    raise exception '회원 이메일 매칭은 정확히 1건이어야 합니다. (email=%, count=%)', v_email, v_member_count;
  end if;

  select mp.user_id, mp.email, mp.name, mp.nickname
  into v_member
  from public.member_profiles mp
  where lower(mp.email) = v_email
  limit 1;

  select count(*)::integer into v_product_count
  from public.products p
  where p.id = any(v_product_ids);

  if v_product_count <> cardinality(v_product_ids) then
    raise exception '상품 ID 중 존재하지 않는 값이 있습니다.';
  end if;

  select p.id, p.title, p.cover_image_url
  into v_primary_product
  from unnest(v_product_ids) with ordinality as input(product_id, ordinality)
  join public.products p on p.id = input.product_id
  order by input.ordinality
  limit 1;

  select jsonb_agg(jsonb_build_object(
    'product_id', p.id,
    'title', p.title,
    'cover_image_url', p.cover_image_url,
    'quantity', 1
  ) order by input.ordinality)
  into v_items
  from unnest(v_product_ids) with ordinality as input(product_id, ordinality)
  join public.products p on p.id = input.product_id;

  v_source_key := encode(digest(
    v_email || E'\n' || v_content || E'\n' || array_to_string(v_product_ids, ','),
    'sha256'
  ), 'hex');

  select lr.id into v_existing_id
  from public.legacy_reviews lr
  where lr.source_key = v_source_key
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'id', -v_existing_id,
      'already_exists', true,
      'points_granted', 0
    );
  end if;

  insert into public.legacy_reviews (
    user_id,
    source,
    source_key,
    rating,
    content,
    photo_urls,
    product_ids,
    primary_product_id,
    primary_title,
    item_count,
    items,
    created_at,
    updated_at
  ) values (
    v_member.user_id,
    'sixshop',
    v_source_key,
    p_rating,
    v_content,
    '{}'::text[],
    v_product_ids,
    v_primary_product.id,
    v_primary_product.title,
    cardinality(v_product_ids),
    v_items,
    v_created_at,
    v_created_at
  )
  returning id into v_review_id;

  if coalesce(p_points, 0) > 0 then
    perform public.grant_points(
      v_member.user_id,
      p_points,
      'admin',
      'admin_adjust',
      p_note => '식스샵 구매 후기 이전 감사 적립'
    );
  end if;

  return jsonb_build_object(
    'id', -v_review_id,
    'already_exists', false,
    'member_email', v_member.email,
    'member_name', v_member.name,
    'product_ids', to_jsonb(v_product_ids),
    'points_granted', coalesce(p_points, 0)
  );
end;
$$;

revoke all on function public.admin_import_legacy_review(text, bigint[], integer, text, timestamptz, integer) from public;
revoke all on function public.admin_import_legacy_review(text, bigint[], integer, text, timestamptz, integer) from anon;
grant execute on function public.admin_import_legacy_review(text, bigint[], integer, text, timestamptz, integer)
  to authenticated, service_role;

commit;

notify pgrst, 'reload schema';

-- Rollback: legacy_reviews를 참조하는 RPC 4종을 직전 정의로 복원한 뒤 테이블을 제거한다.
