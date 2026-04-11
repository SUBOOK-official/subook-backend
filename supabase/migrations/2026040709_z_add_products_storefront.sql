-- Add first-class storefront products and link public inventory books to them.

create extension if not exists pgcrypto;

create table if not exists public.products (
  id bigint generated always as identity primary key,
  group_key text not null unique,
  title text not null,
  option text null,
  subject text not null,
  brand text not null,
  book_type text not null,
  published_year integer not null,
  instructor_name text null,
  cover_image_url text null,
  status text not null default 'selling' check (status in ('selling', 'sold_out', 'hidden')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.products
  add constraint products_title_check
  check (nullif(btrim(coalesce(title, '')), '') is not null),
  add constraint products_subject_check
  check (nullif(btrim(coalesce(subject, '')), '') is not null and subject in ('국어', '수학', '영어', '과학', '사회', '한국사', '기타')),
  add constraint products_brand_check
  check (nullif(btrim(coalesce(brand, '')), '') is not null and brand in ('시대인재', '강남대성', '대성마이맥', '이투스', 'EBS')),
  add constraint products_book_type_check
  check (nullif(btrim(coalesce(book_type, '')), '') is not null and book_type in ('기출', '모의고사', 'N제', 'EBS', '주간지', '내신')),
  add constraint products_published_year_check
  check (published_year >= 2000 and published_year <= 2100);

create index if not exists idx_products_group_key
  on public.products (group_key);

create index if not exists idx_products_public_storefront_filters
  on public.products (subject, brand, book_type, published_year)
  where status <> 'hidden';

alter table public.books
  add column if not exists product_id bigint null references public.products(id) on delete set null;

create index if not exists idx_books_product_id
  on public.books (product_id);

create index if not exists idx_books_product_public_storefront
  on public.books (product_id, condition_grade, price)
  where status = 'on_sale' and is_public = true;

alter table public.products enable row level security;

drop policy if exists products_select_public on public.products;
drop policy if exists products_insert_admin on public.products;
drop policy if exists products_update_admin on public.products;
drop policy if exists products_delete_admin on public.products;

create policy products_select_public
  on public.products
  for select
  to anon, authenticated
  using (true);

create policy products_insert_admin
  on public.products
  for insert
  to authenticated
  with check (public.is_admin_user());

create policy products_update_admin
  on public.products
  for update
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create policy products_delete_admin
  on public.products
  for delete
  to authenticated
  using (public.is_admin_user());

create or replace function public.storefront_condition_grade_rank(p_condition_grade text)
returns integer
language sql
immutable
set search_path = public
as $$
  select case coalesce(upper(btrim(coalesce(p_condition_grade, ''))), '')
    when 'S' then 1
    when 'A_PLUS' then 2
    when 'A' then 3
    else 99
  end;
$$;

create or replace function public.storefront_product_group_key(
  p_title text,
  p_option text,
  p_subject text,
  p_brand text,
  p_book_type text,
  p_published_year integer,
  p_instructor_name text
)
returns text
language sql
immutable
set search_path = public
as $$
  select encode(
    extensions.digest(
      jsonb_build_array(
        lower(btrim(coalesce(p_title, ''))),
        lower(btrim(coalesce(p_option, ''))),
        lower(btrim(coalesce(p_subject, ''))),
        lower(btrim(coalesce(p_brand, ''))),
        lower(btrim(coalesce(p_book_type, ''))),
        coalesce(p_published_year::text, ''),
        lower(btrim(coalesce(p_instructor_name, '')))
      )::text,
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function public.refresh_storefront_product_status(p_product_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  next_title text;
  next_option text;
  next_subject text;
  next_brand text;
  next_book_type text;
  next_published_year integer;
  next_instructor_name text;
  next_cover_image_url text;
  next_public_on_sale_count integer;
  next_public_book_count integer;
begin
  select
    b.title,
    b.option,
    b.subject,
    b.brand,
    b.book_type,
    b.published_year,
    b.instructor_name,
    b.cover_image_url
  into
    next_title,
    next_option,
    next_subject,
    next_brand,
    next_book_type,
    next_published_year,
    next_instructor_name,
    next_cover_image_url
  from public.books b
  where b.product_id = p_product_id
    and b.status = 'on_sale'
    and b.is_public = true
  order by
    public.storefront_condition_grade_rank(b.condition_grade),
    b.price asc nulls last,
    b.created_at desc,
    b.id desc
  limit 1;

  select
    count(*) filter (where b.status = 'on_sale' and b.is_public)::integer,
    count(*) filter (where b.is_public)::integer
  into
    next_public_on_sale_count,
    next_public_book_count
  from public.books b
  where b.product_id = p_product_id;

  update public.products p
  set
    title = coalesce(next_title, p.title),
    option = coalesce(next_option, p.option),
    subject = coalesce(next_subject, p.subject),
    brand = coalesce(next_brand, p.brand),
    book_type = coalesce(next_book_type, p.book_type),
    published_year = coalesce(next_published_year, p.published_year),
    instructor_name = coalesce(next_instructor_name, p.instructor_name),
    cover_image_url = coalesce(next_cover_image_url, p.cover_image_url),
    status = case
      when next_public_on_sale_count > 0 then 'selling'
      when next_public_book_count > 0 then 'sold_out'
      else 'hidden'
    end,
    updated_at = now()
  where p.id = p_product_id;
end;
$$;

create or replace function public.books_enforce_public_storefront_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_group_key text;
begin
  if new.status is distinct from 'on_sale' then
    new.is_public := false;
    new.product_id := null;
    return new;
  end if;

  if coalesce(new.is_public, false) then
    if nullif(btrim(coalesce(new.title, '')), '') is null then
      raise exception 'Public books require a title.';
    end if;

    if nullif(btrim(coalesce(new.subject, '')), '') is null then
      raise exception 'Public books require a subject.';
    end if;

    if nullif(btrim(coalesce(new.brand, '')), '') is null then
      raise exception 'Public books require a brand.';
    end if;

    if nullif(btrim(coalesce(new.book_type, '')), '') is null then
      raise exception 'Public books require a book type.';
    end if;

    if new.published_year is null then
      raise exception 'Public books require a published year.';
    end if;

    if new.original_price is null then
      raise exception 'Public books require an original price.';
    end if;

    if new.price is null then
      raise exception 'Public books require a sale price.';
    end if;

    if nullif(btrim(coalesce(new.cover_image_url, '')), '') is null then
      raise exception 'Public books require a cover image.';
    end if;

    if nullif(btrim(coalesce(new.condition_grade, '')), '') is null then
      raise exception 'Public books require a condition grade.';
    end if;

    if new.writing_percentage is null then
      raise exception 'Public books require a writing percentage.';
    end if;

    if new.has_damage is null then
      raise exception 'Public books require a damage flag.';
    end if;

    if new.inspected_at is null then
      raise exception 'Public books require an inspection timestamp.';
    end if;

    next_group_key := public.storefront_product_group_key(
      new.title,
      new.option,
      new.subject,
      new.brand,
      new.book_type,
      new.published_year,
      new.instructor_name
    );

    insert into public.products (
      group_key,
      title,
      option,
      subject,
      brand,
      book_type,
      published_year,
      instructor_name,
      cover_image_url,
      status
    )
    values (
      next_group_key,
      new.title,
      new.option,
      new.subject,
      new.brand,
      new.book_type,
      new.published_year,
      new.instructor_name,
      new.cover_image_url,
      'selling'
    )
    on conflict (group_key) do update
    set
      title = excluded.title,
      option = excluded.option,
      subject = excluded.subject,
      brand = excluded.brand,
      book_type = excluded.book_type,
      published_year = excluded.published_year,
      instructor_name = excluded.instructor_name,
      cover_image_url = coalesce(excluded.cover_image_url, public.products.cover_image_url),
      status = 'selling',
      updated_at = now()
    returning id into new.product_id;
  else
    new.product_id := null;
  end if;

  return new;
end;
$$;

drop trigger if exists books_enforce_public_storefront_rules_trigger on public.books;
create trigger books_enforce_public_storefront_rules_trigger
before insert or update on public.books
for each row
execute function public.books_enforce_public_storefront_rules();

create or replace function public.books_refresh_storefront_product_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.product_id is not null then
      perform public.refresh_storefront_product_status(old.product_id);
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.product_id is not null and old.product_id is distinct from new.product_id then
    perform public.refresh_storefront_product_status(old.product_id);
  end if;

  if tg_op in ('INSERT', 'UPDATE') and new.product_id is not null then
    perform public.refresh_storefront_product_status(new.product_id);
  end if;

  return new;
end;
$$;

drop trigger if exists books_refresh_storefront_product_status_trigger on public.books;
create trigger books_refresh_storefront_product_status_trigger
after insert or update or delete on public.books
for each row
execute function public.books_refresh_storefront_product_status();

with storefront_groups as (
  select distinct on (
    public.storefront_product_group_key(
      b.title,
      b.option,
      b.subject,
      b.brand,
      b.book_type,
      b.published_year,
      b.instructor_name
    )
  )
    public.storefront_product_group_key(
      b.title,
      b.option,
      b.subject,
      b.brand,
      b.book_type,
      b.published_year,
      b.instructor_name
    ) as group_key,
    b.title,
    b.option,
    b.subject,
    b.brand,
    b.book_type,
    b.published_year,
    b.instructor_name,
    b.cover_image_url
  from public.books b
  where b.status = 'on_sale'
    and b.is_public = true
  order by
    public.storefront_product_group_key(
      b.title,
      b.option,
      b.subject,
      b.brand,
      b.book_type,
      b.published_year,
      b.instructor_name
    ),
    public.storefront_condition_grade_rank(b.condition_grade),
    b.price asc nulls last,
    b.created_at desc,
    b.id desc
)
insert into public.products (
  group_key,
  title,
  option,
  subject,
  brand,
  book_type,
  published_year,
  instructor_name,
  cover_image_url,
  status
)
select
  group_key,
  title,
  option,
  subject,
  brand,
  book_type,
  published_year,
  instructor_name,
  cover_image_url,
  'selling'
from storefront_groups
on conflict (group_key) do update
set
  title = excluded.title,
  option = excluded.option,
  subject = excluded.subject,
  brand = excluded.brand,
  book_type = excluded.book_type,
  published_year = excluded.published_year,
  instructor_name = excluded.instructor_name,
  cover_image_url = coalesce(excluded.cover_image_url, public.products.cover_image_url),
  status = 'selling',
  updated_at = now();

update public.books b
set product_id = p.id
from public.products p
where p.group_key = public.storefront_product_group_key(
  b.title,
  b.option,
  b.subject,
  b.brand,
  b.book_type,
  b.published_year,
  b.instructor_name
)
  and b.status = 'on_sale'
  and b.is_public = true
  and b.product_id is distinct from p.id;

create or replace function public.list_public_store_products(
  p_subjects text[] default null,
  p_book_types text[] default null,
  p_brands text[] default null,
  p_years integer[] default null,
  p_condition_grades text[] default null,
  p_search text default null,
  p_sort text default 'popular',
  p_limit integer default 24,
  p_offset integer default 0
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
  popularity_score integer,
  available_option_count integer,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      lower(coalesce(btrim(p_sort), 'popular')) as sort_key,
      btrim(coalesce(p_search, '')) as search_term
  ),
  candidate_books as (
    select
      p.id as product_id,
      p.title,
      p.option,
      p.subject,
      p.brand,
      p.book_type,
      p.published_year,
      p.instructor_name,
      p.cover_image_url as product_cover_image_url,
      b.id as book_id,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url as book_cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at as book_created_at,
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank,
      (
        case coalesce(b.condition_grade, '')
          when 'S' then 300
          when 'A_PLUS' then 200
          when 'A' then 100
          else 0
        end
        + greatest(0, coalesce(b.original_price - b.price, 0) / 100)
        + greatest(0, 100 - coalesce(b.writing_percentage, 100))
        + case
            when b.inspected_at is null then 0
            else greatest(0, 30 - least(30, floor(extract(day from now() - b.inspected_at))::integer))
          end
      )::integer as popularity_score
    from public.products p
    join public.books b
      on b.product_id = p.id
    cross join params
    where b.status = 'on_sale'
      and b.is_public = true
      and (coalesce(cardinality(p_subjects), 0) = 0 or p.subject = any(p_subjects))
      and (coalesce(cardinality(p_book_types), 0) = 0 or p.book_type = any(p_book_types))
      and (coalesce(cardinality(p_brands), 0) = 0 or p.brand = any(p_brands))
      and (coalesce(cardinality(p_years), 0) = 0 or p.published_year = any(p_years))
      and (
        coalesce(cardinality(p_condition_grades), 0) = 0
        or b.condition_grade = any(p_condition_grades)
      )
      and (
        params.search_term = ''
        or p.title ilike '%' || params.search_term || '%'
        or coalesce(p.option, '') ilike '%' || params.search_term || '%'
        or coalesce(p.subject, '') ilike '%' || params.search_term || '%'
        or coalesce(p.brand, '') ilike '%' || params.search_term || '%'
        or coalesce(p.book_type, '') ilike '%' || params.search_term || '%'
        or coalesce(p.instructor_name, '') ilike '%' || params.search_term || '%'
        or coalesce(b.condition_grade, '') ilike '%' || params.search_term || '%'
        or coalesce(b.option, '') ilike '%' || params.search_term || '%'
        or coalesce(b.published_year::text, '') ilike '%' || params.search_term || '%'
      )
  ),
  ranked_books as (
    select
      candidate_books.*,
      row_number() over (
        partition by candidate_books.product_id
        order by
          candidate_books.price asc nulls last,
          candidate_books.condition_rank asc,
          candidate_books.book_created_at desc,
          candidate_books.book_id desc
      ) as representative_rank,
      count(*) over (partition by candidate_books.product_id) as available_option_count,
      max(candidate_books.popularity_score) over (partition by candidate_books.product_id) as product_popularity_score,
      max(candidate_books.book_created_at) over (partition by candidate_books.product_id) as latest_book_created_at
    from candidate_books
  ),
  representative_products as (
    select *
    from ranked_books
    where representative_rank = 1
  ),
  ordered as (
    select
      representative_products.*,
      params.sort_key
    from representative_products
    cross join params
    order by
      case when params.sort_key = 'latest' then representative_products.latest_book_created_at end desc nulls last,
      case when params.sort_key = 'price_low' then representative_products.price end asc nulls last,
      case when params.sort_key = 'price_high' then representative_products.price end desc nulls last,
      case when params.sort_key = 'popular' then representative_products.product_popularity_score end desc nulls last,
      representative_products.latest_book_created_at desc,
      representative_products.product_id desc
  )
  select
    ordered.product_id as id,
    ordered.product_id,
    ordered.title,
    ordered.option,
    ordered.subject,
    ordered.brand,
    ordered.book_type,
    ordered.published_year,
    ordered.instructor_name,
    ordered.condition_grade,
    ordered.price,
    ordered.original_price,
    ordered.discount_rate,
    coalesce(ordered.book_cover_image_url, ordered.product_cover_image_url) as cover_image_url,
    ordered.inspection_image_urls,
    ordered.writing_percentage,
    ordered.has_damage,
    ordered.inspection_notes,
    ordered.inspected_at,
    ordered.latest_book_created_at as created_at,
    ordered.product_popularity_score as popularity_score,
    ordered.available_option_count,
    count(*) over()::integer as total_count
  from ordered
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 24), 500));
$$;

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
  option_books jsonb
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
          and b.status = 'on_sale'
          and b.is_public = true
      )
    limit 1
  ),
  representative_book as (
    select
      b.id as book_id,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url as book_cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at as book_created_at
    from public.books b
    join target_product p
      on p.id = b.product_id
    where b.status = 'on_sale'
      and b.is_public = true
    order by
      public.storefront_condition_grade_rank(b.condition_grade),
      b.price asc nulls last,
      b.created_at desc,
      b.id desc
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
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank
    from public.books b
    join target_product p
      on p.id = b.product_id
    where b.status = 'on_sale'
      and b.is_public = true
  ),
  option_books as (
    select coalesce(
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
          'created_at', option_book_rows.created_at
        )
        order by
          option_book_rows.condition_rank,
          option_book_rows.price asc nulls last,
          option_book_rows.created_at desc,
          option_book_rows.book_id desc
      ),
      '[]'::jsonb
    ) as option_books
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
    target_product.created_at,
    related_books.related_books,
    option_books.option_books
  from target_product
  left join representative_book on true
  cross join related_books
  cross join option_books;
$$;

drop function if exists public.list_public_store_books(text[], text[], text[], integer[], text[], text, text, integer, integer);
drop function if exists public.get_public_store_book_detail(bigint);

create or replace function public.list_public_store_books(
  p_subjects text[] default null,
  p_book_types text[] default null,
  p_brands text[] default null,
  p_years integer[] default null,
  p_condition_grades text[] default null,
  p_search text default null,
  p_sort text default 'popular',
  p_limit integer default 24,
  p_offset integer default 0
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
  popularity_score integer,
  available_option_count integer,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    product_books.id,
    product_books.product_id,
    product_books.title,
    product_books.option,
    product_books.subject,
    product_books.brand,
    product_books.book_type,
    product_books.published_year,
    product_books.instructor_name,
    product_books.condition_grade,
    product_books.price,
    product_books.original_price,
    product_books.discount_rate,
    product_books.cover_image_url,
    product_books.inspection_image_urls,
    product_books.writing_percentage,
    product_books.has_damage,
    product_books.inspection_notes,
    product_books.inspected_at,
    product_books.created_at,
    product_books.popularity_score,
    product_books.available_option_count,
    product_books.total_count
  from public.list_public_store_products(
    p_subjects,
    p_book_types,
    p_brands,
    p_years,
    p_condition_grades,
    p_search,
    p_sort,
    p_limit,
    p_offset
  ) as product_books;
$$;

create or replace function public.get_public_store_book_detail(
  p_book_id bigint
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
  option_books jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  with target_product as (
    select coalesce(
      (
        select p.id
        from public.products p
        where p.id = p_book_id
          and exists (
            select 1
            from public.books b
            where b.product_id = p.id
              and b.status = 'on_sale'
              and b.is_public = true
          )
        limit 1
      ),
      (
        select b.product_id
        from public.books b
        where b.id = p_book_id
          and b.product_id is not null
        limit 1
      ),
      (
        select p.id
        from public.books b
        join public.products p
          on p.group_key = public.storefront_product_group_key(
            b.title,
            b.option,
            b.subject,
            b.brand,
            b.book_type,
            b.published_year,
            b.instructor_name
          )
        where b.id = p_book_id
        limit 1
      )
    ) as product_id
  )
  select *
  from public.get_public_store_product_detail((select product_id from target_product));
$$;

grant execute on function public.storefront_condition_grade_rank(text) to anon, authenticated;
grant execute on function public.storefront_product_group_key(text, text, text, text, text, integer, text) to anon, authenticated;
grant execute on function public.list_public_store_products(text[], text[], text[], integer[], text[], text, text, integer, integer) to anon, authenticated;
grant execute on function public.get_public_store_product_detail(bigint) to anon, authenticated;
grant execute on function public.list_public_store_books(text[], text[], text[], integer[], text[], text, text, integer, integer) to anon, authenticated;
grant execute on function public.get_public_store_book_detail(bigint) to anon, authenticated;
