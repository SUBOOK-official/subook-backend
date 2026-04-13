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

create or replace function public.get_public_store_product_detail(
  p_product_id bigint
)
returns table (
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
  with target_product as (
    select p.*
    from public.products p
    where p.id = p_product_id
      and exists (
        select 1
        from public.books b
        where b.product_id = p.id
          and b.is_public = true
      )
    limit 1
  ),
  option_book_rows as (
    select
      b.id as book_id,
      b.product_id,
      b.title,
      b.option,
      b.subject,
      b.brand,
      b.book_type,
      b.published_year,
      b.instructor_name,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at,
      (b.status = 'on_sale' and b.is_public) as is_available,
      case
        when b.status = 'on_sale' and b.is_public then 'selling'
        else 'sold_out'
      end as availability_status,
      case
        when b.status = 'on_sale' and b.is_public then 1
        else 0
      end as stock_count,
      case
        when b.status = 'on_sale' and b.is_public then 0
        else 1
      end as availability_rank,
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank
    from public.books b
    join target_product p
      on p.id = b.product_id
    where b.is_public = true
  ),
  representative_book as (
    select
      option_book_rows.book_id,
      option_book_rows.condition_grade,
      option_book_rows.price,
      option_book_rows.original_price,
      option_book_rows.discount_rate,
      option_book_rows.cover_image_url as book_cover_image_url,
      option_book_rows.inspection_image_urls,
      option_book_rows.writing_percentage,
      option_book_rows.has_damage,
      option_book_rows.inspection_notes,
      option_book_rows.inspected_at,
      option_book_rows.created_at as book_created_at
    from option_book_rows
    order by
      option_book_rows.availability_rank,
      option_book_rows.condition_rank,
      option_book_rows.price asc nulls last,
      option_book_rows.created_at desc,
      option_book_rows.book_id desc
    limit 1
  ),
  option_books as (
    select
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'book_id', option_book_rows.book_id,
            'product_id', option_book_rows.product_id,
            'title', option_book_rows.title,
            'option', option_book_rows.option,
            'subject', option_book_rows.subject,
            'brand', option_book_rows.brand,
            'book_type', option_book_rows.book_type,
            'published_year', option_book_rows.published_year,
            'instructor_name', option_book_rows.instructor_name,
            'condition_grade', option_book_rows.condition_grade,
            'price', option_book_rows.price,
            'original_price', option_book_rows.original_price,
            'discount_rate', option_book_rows.discount_rate,
            'cover_image_url', option_book_rows.cover_image_url,
            'inspection_image_urls', option_book_rows.inspection_image_urls,
            'writing_percentage', option_book_rows.writing_percentage,
            'has_damage', option_book_rows.has_damage,
            'inspection_notes', option_book_rows.inspection_notes,
            'inspected_at', option_book_rows.inspected_at,
            'created_at', option_book_rows.created_at,
            'status', option_book_rows.availability_status,
            'is_available', option_book_rows.is_available,
            'stock_count', option_book_rows.stock_count
          )
          order by
            option_book_rows.availability_rank,
            option_book_rows.condition_rank,
            option_book_rows.price asc nulls last,
            option_book_rows.created_at desc,
            option_book_rows.book_id desc
        ),
        '[]'::jsonb
      ) as option_books,
      count(*) filter (where option_book_rows.is_available)::integer as available_option_count,
      count(*) filter (where not option_book_rows.is_available)::integer as sold_out_option_count,
      count(*)::integer as total_option_count
    from option_book_rows
  ),
  related_books as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', related_product.id,
          'product_id', related_product.product_id,
          'title', related_product.title,
          'option', related_product.option,
          'subject', related_product.subject,
          'brand', related_product.brand,
          'book_type', related_product.book_type,
          'published_year', related_product.published_year,
          'instructor_name', related_product.instructor_name,
          'condition_grade', related_product.condition_grade,
          'price', related_product.price,
          'original_price', related_product.original_price,
          'discount_rate', related_product.discount_rate,
          'cover_image_url', related_product.cover_image_url,
          'inspection_image_urls', related_product.inspection_image_urls,
          'writing_percentage', related_product.writing_percentage,
          'has_damage', related_product.has_damage,
          'inspection_notes', related_product.inspection_notes,
          'inspected_at', related_product.inspected_at,
          'created_at', related_product.created_at,
          'popularity_score', related_product.popularity_score,
          'available_option_count', related_product.available_option_count
        )
        order by related_product.popularity_score desc, related_product.created_at desc, related_product.id desc
      ),
      '[]'::jsonb
    ) as related_books
    from target_product tp
    cross join lateral (
      select *
      from public.list_public_store_products(
        array[tp.subject],
        array[tp.book_type],
        array[tp.brand],
        array[tp.published_year],
        null,
        null,
        'popular',
        6,
        0
      )
      where id <> tp.id
    ) related_product
  )
  select
    target_product.id,
    target_product.id,
    target_product.title,
    target_product.option,
    target_product.subject,
    target_product.brand,
    target_product.book_type,
    target_product.published_year,
    target_product.instructor_name,
    representative_book.condition_grade,
    representative_book.price,
    representative_book.original_price,
    representative_book.discount_rate,
    coalesce(representative_book.book_cover_image_url, target_product.cover_image_url) as cover_image_url,
    representative_book.inspection_image_urls,
    representative_book.writing_percentage,
    representative_book.has_damage,
    representative_book.inspection_notes,
    representative_book.inspected_at,
    representative_book.book_created_at as created_at,
    related_books.related_books,
    option_books.option_books,
    option_books.available_option_count,
    option_books.sold_out_option_count,
    option_books.total_option_count
  from target_product
  left join representative_book on true
  cross join related_books
  cross join option_books;
$$;

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
