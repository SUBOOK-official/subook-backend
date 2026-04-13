create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  order_id bigint not null references public.orders(id) on delete cascade,
  order_item_id bigint not null references public.order_items(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  author_name text not null,
  rating integer not null check (rating between 1 and 5),
  content text not null check (char_length(btrim(coalesce(content, ''))) between 1 and 200),
  photo_urls text[] not null default '{}'::text[] check (coalesce(cardinality(photo_urls), 0) <= 3),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_item_id)
);

create index if not exists idx_reviews_product_created_at
  on public.reviews (product_id, created_at desc)
  where is_hidden = false;

create index if not exists idx_reviews_user_created_at
  on public.reviews (user_id, created_at desc);

alter table public.reviews enable row level security;

drop policy if exists "reviews_select_public_visible" on public.reviews;
create policy "reviews_select_public_visible"
  on public.reviews
  for select
  to anon, authenticated
  using (not is_hidden or user_id = auth.uid() or public.is_admin_user());

drop policy if exists "reviews_admin_all" on public.reviews;
create policy "reviews_admin_all"
  on public.reviews
  for all
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create or replace function public.touch_reviews_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists reviews_set_updated_at on public.reviews;
create trigger reviews_set_updated_at
before update on public.reviews
for each row
execute function public.touch_reviews_updated_at();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'review-images',
  'review-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "review_images_select_public" on storage.objects;
create policy "review_images_select_public"
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'review-images');

drop policy if exists "review_images_insert_own" on storage.objects;
create policy "review_images_insert_own"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'review-images'
    and owner = auth.uid()
    and name like auth.uid()::text || '/%'
  );

drop policy if exists "review_images_update_own" on storage.objects;
create policy "review_images_update_own"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'review-images'
    and owner = auth.uid()
    and name like auth.uid()::text || '/%'
  )
  with check (
    bucket_id = 'review-images'
    and owner = auth.uid()
    and name like auth.uid()::text || '/%'
  );

drop policy if exists "review_images_delete_own" on storage.objects;
create policy "review_images_delete_own"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'review-images'
    and owner = auth.uid()
    and name like auth.uid()::text || '/%'
  );

create or replace function public.create_product_review(
  p_order_item_id bigint,
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
  v_user_id uuid;
  v_order_item record;
  v_author_name text;
  v_content text;
  v_photo_urls text[];
  v_review_id bigint;
  v_created_at timestamptz;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception '별점은 1점부터 5점까지 선택해 주세요.';
  end if;

  v_content := left(btrim(coalesce(p_content, '')), 200);
  if v_content = '' then
    raise exception '리뷰 내용을 입력해 주세요.';
  end if;

  select coalesce(array_agg(normalized_photo order by ordinality), '{}'::text[])
  into v_photo_urls
  from (
    select
      nullif(btrim(photo_url), '') as normalized_photo,
      ordinality
    from unnest(coalesce(p_photo_urls, '{}'::text[])) with ordinality as photo(photo_url, ordinality)
  ) normalized_photos
  where normalized_photo is not null;

  if coalesce(cardinality(v_photo_urls), 0) > 3 then
    raise exception '리뷰 사진은 최대 3장까지 첨부할 수 있습니다.';
  end if;

  select
    oi.id as order_item_id,
    oi.order_id,
    oi.product_id,
    o.status as order_status
  into v_order_item
  from public.order_items oi
  join public.orders o
    on o.id = oi.order_id
  where oi.id = p_order_item_id
    and o.user_id = v_user_id
  limit 1;

  if not found then
    raise exception '구매한 상품만 리뷰를 작성할 수 있습니다.';
  end if;

  if v_order_item.order_status <> 'confirmed' then
    raise exception '구매확정 후에 리뷰를 작성할 수 있습니다.';
  end if;

  if v_order_item.product_id is null then
    raise exception '리뷰 대상 상품 정보를 찾을 수 없습니다.';
  end if;

  if exists (
    select 1
    from public.reviews r
    where r.order_item_id = v_order_item.order_item_id
  ) then
    raise exception '이미 리뷰를 작성한 상품입니다.';
  end if;

  select coalesce(
    nullif(btrim(mp.nickname), ''),
    nullif(btrim(mp.name), ''),
    nullif(split_part(lower(coalesce(mp.email, '')), '@', 1), ''),
    '회원'
  )
  into v_author_name
  from public.member_profiles mp
  where mp.user_id = v_user_id;

  v_author_name := coalesce(nullif(btrim(v_author_name), ''), '회원');

  insert into public.reviews (
    user_id,
    order_id,
    order_item_id,
    product_id,
    author_name,
    rating,
    content,
    photo_urls
  )
  values (
    v_user_id,
    v_order_item.order_id,
    v_order_item.order_item_id,
    v_order_item.product_id,
    v_author_name,
    p_rating,
    v_content,
    v_photo_urls
  )
  returning id, created_at
  into v_review_id, v_created_at;

  return jsonb_build_object(
    'id', v_review_id,
    'order_id', v_order_item.order_id,
    'order_item_id', v_order_item.order_item_id,
    'product_id', v_order_item.product_id,
    'author_name', v_author_name,
    'rating', p_rating,
    'content', v_content,
    'photo_urls', v_photo_urls,
    'created_at', v_created_at
  );
exception
  when unique_violation then
    raise exception '이미 리뷰를 작성한 상품입니다.';
end;
$$;

revoke all on function public.create_product_review(bigint, integer, text, text[]) from public;
grant execute on function public.create_product_review(bigint, integer, text, text[]) to authenticated;

create or replace function public.get_public_product_reviews(
  p_product_id bigint,
  p_sort text default 'latest',
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      case lower(coalesce(btrim(p_sort), 'latest'))
        when 'rating_high' then 'rating_high'
        when 'rating_low' then 'rating_low'
        else 'latest'
      end as sort_key,
      greatest(1, least(coalesce(p_limit, 20), 50)) as limit_count,
      greatest(0, coalesce(p_offset, 0)) as offset_count
  ),
  visible_reviews as (
    select
      r.id,
      r.product_id,
      r.order_item_id,
      r.author_name,
      r.rating,
      r.content,
      r.photo_urls,
      r.created_at
    from public.reviews r
    where r.product_id = p_product_id
      and not r.is_hidden
  ),
  summary as (
    select
      count(*)::integer as total_count,
      coalesce(round(avg(rating)::numeric, 1), 0) as average_rating,
      count(*) filter (where rating = 5)::integer as rating_5_count,
      count(*) filter (where rating = 4)::integer as rating_4_count,
      count(*) filter (where rating = 3)::integer as rating_3_count,
      count(*) filter (where rating = 2)::integer as rating_2_count,
      count(*) filter (where rating = 1)::integer as rating_1_count
    from visible_reviews
  ),
  ranked_reviews as (
    select
      vr.*,
      row_number() over (
        order by
          case when params.sort_key = 'rating_high' then vr.rating end desc nulls last,
          case when params.sort_key = 'rating_low' then vr.rating end asc nulls last,
          case when params.sort_key = 'latest' then vr.created_at end desc nulls last,
          vr.created_at desc,
          vr.id desc
      ) as sort_index
    from visible_reviews vr
    cross join params
  ),
  paged_reviews as (
    select rr.*
    from ranked_reviews rr
    cross join params
    where rr.sort_index > params.offset_count
      and rr.sort_index <= params.offset_count + params.limit_count
    order by rr.sort_index
  )
  select jsonb_build_object(
    'summary',
    jsonb_build_object(
      'average_rating', summary.average_rating,
      'total_count', summary.total_count,
      'rating_counts',
      jsonb_build_object(
        '5', summary.rating_5_count,
        '4', summary.rating_4_count,
        '3', summary.rating_3_count,
        '2', summary.rating_2_count,
        '1', summary.rating_1_count
      )
    ),
    'sort', params.sort_key,
    'has_more', summary.total_count > params.offset_count + params.limit_count,
    'reviews',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pr.id,
            'product_id', pr.product_id,
            'order_item_id', pr.order_item_id,
            'author_name', pr.author_name,
            'rating', pr.rating,
            'content', pr.content,
            'photo_urls', pr.photo_urls,
            'created_at', pr.created_at
          )
          order by pr.sort_index
        )
        from paged_reviews pr
      ),
      '[]'::jsonb
    )
  )
  from summary
  cross join params;
$$;

revoke all on function public.get_public_product_reviews(bigint, text, integer, integer) from public;
grant execute on function public.get_public_product_reviews(bigint, text, integer, integer) to anon, authenticated;

create or replace function public.get_my_orders(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      'discount_amount', o.discount_amount,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'product_id', oi.product_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          'review_id', rv.id,
          'review_rating', rv.rating,
          'review_created_at', rv.created_at
        ) order by oi.id)
        from public.order_items oi
        left join public.reviews rv
          on rv.order_item_id = oi.id
         and rv.user_id = v_user_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    where o.user_id = v_user_id
    order by o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;
