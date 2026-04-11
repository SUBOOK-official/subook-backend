-- Subook seller mini site schema

create extension if not exists pgcrypto;

create table if not exists public.shipments (
  id bigint generated always as identity primary key,
  user_id uuid null references auth.users(id) on delete set null,
  seller_name text not null,
  seller_phone text not null,
  pickup_date date not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'inspecting', 'inspected')),
  created_at timestamptz not null default now()
);

create table if not exists public.books (
  id bigint generated always as identity primary key,
  shipment_id bigint not null references public.shipments(id) on delete cascade,
  title text not null,
  option text null,
  subject text null,
  brand text null,
  book_type text null,
  published_year integer null,
  instructor_name text null,
  original_price integer null check (original_price is null or original_price >= 0),
  condition_grade text null,
  cover_image_url text null,
  inspection_image_urls text[] not null default '{}'::text[],
  writing_percentage integer null check (writing_percentage is null or (writing_percentage >= 0 and writing_percentage <= 100)),
  has_damage boolean null,
  inspection_notes text null,
  inspected_at timestamptz null,
  is_public boolean not null default false,
  product_id bigint null references public.products(id) on delete set null,
  status text not null default 'on_sale' check (status in ('on_sale', 'settled')),
  price integer null check (price is null or price >= 0),
  created_at timestamptz not null default now()
);

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

create table if not exists public.admin_users (
  email text primary key,
  created_at timestamptz not null default now()
);

alter table public.books
  add column if not exists option text null;

create index if not exists idx_shipments_seller_lookup
  on public.shipments (seller_name, seller_phone, created_at desc);

create index if not exists idx_books_shipment_id
  on public.books (shipment_id);

create index if not exists idx_books_product_id
  on public.books (product_id);

create index if not exists idx_books_public_storefront_created_at
  on public.books (created_at desc, id desc)
  where status = 'on_sale' and is_public = true;

create index if not exists idx_books_public_storefront_filters
  on public.books (subject, brand, book_type, published_year, condition_grade)
  where status = 'on_sale' and is_public = true;

create index if not exists idx_products_group_key
  on public.products (group_key);

create index if not exists idx_products_public_storefront_filters
  on public.products (subject, brand, book_type, published_year)
  where status <> 'hidden';

alter table public.products
  add constraint products_title_check
  check (nullif(btrim(coalesce(title, '')), '') is not null);

alter table public.products
  add constraint products_subject_check
  check (nullif(btrim(coalesce(subject, '')), '') is not null and subject in ('국어', '수학', '영어', '과학', '사회', '한국사', '기타'));

alter table public.products
  add constraint products_brand_check
  check (nullif(btrim(coalesce(brand, '')), '') is not null and brand in ('시대인재', '강남대성', '대성마이맥', '이투스', 'EBS'));

alter table public.products
  add constraint products_book_type_check
  check (nullif(btrim(coalesce(book_type, '')), '') is not null and book_type in ('기출', '모의고사', 'N제', 'EBS', '주간지', '내신'));

alter table public.products
  add constraint products_published_year_check
  check (published_year >= 2000 and published_year <= 2100);

alter table public.books
  add constraint books_subject_check
  check (subject is null or subject in ('국어', '수학', '영어', '과학', '사회', '한국사', '기타'));

alter table public.books
  add constraint books_brand_check
  check (brand is null or brand in ('시대인재', '강남대성', '대성마이맥', '이투스', 'EBS'));

alter table public.books
  add constraint books_book_type_check
  check (book_type is null or book_type in ('기출', '모의고사', 'N제', 'EBS', '주간지', '내신'));

alter table public.books
  add constraint books_published_year_check
  check (published_year is null or (published_year >= 2000 and published_year <= 2100));

alter table public.books
  add constraint books_condition_grade_check
  check (condition_grade is null or condition_grade in ('S', 'A_PLUS', 'A'));

alter table public.books
  add constraint books_public_storefront_ready_check
  check (
    not is_public
    or (
      status = 'on_sale'
      and nullif(btrim(coalesce(title, '')), '') is not null
      and nullif(btrim(coalesce(subject, '')), '') is not null
      and nullif(btrim(coalesce(brand, '')), '') is not null
      and nullif(btrim(coalesce(book_type, '')), '') is not null
      and published_year is not null
      and original_price is not null
      and price is not null
      and nullif(btrim(coalesce(cover_image_url, '')), '') is not null
      and condition_grade is not null
      and writing_percentage is not null
      and has_damage is not null
      and inspected_at is not null
    )
  );

create or replace function public.books_enforce_public_storefront_rules()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status is distinct from 'on_sale' then
    new.is_public := false;
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
  end if;

  return new;
end;
$$;

drop trigger if exists books_enforce_public_storefront_rules_trigger on public.books;
create trigger books_enforce_public_storefront_rules_trigger
before insert or update on public.books
for each row
execute function public.books_enforce_public_storefront_rules();

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

create index if not exists idx_shipments_user_id_created_at
  on public.shipments (user_id, created_at desc);

create index if not exists idx_admin_users_email_lower
  on public.admin_users (lower(email));

alter table public.shipments enable row level security;
alter table public.books enable row level security;
alter table public.admin_users enable row level security;

drop policy if exists shipments_select_public on public.shipments;
drop policy if exists shipments_insert_public on public.shipments;
drop policy if exists shipments_update_public on public.shipments;
drop policy if exists shipments_delete_public on public.shipments;
drop policy if exists books_select_public on public.books;
drop policy if exists books_insert_public on public.books;
drop policy if exists books_update_public on public.books;
drop policy if exists books_delete_public on public.books;

drop policy if exists shipments_select_admin on public.shipments;
drop policy if exists shipments_insert_admin on public.shipments;
drop policy if exists shipments_update_admin on public.shipments;
drop policy if exists shipments_delete_admin on public.shipments;
drop policy if exists books_select_admin on public.books;
drop policy if exists books_insert_admin on public.books;
drop policy if exists books_update_admin on public.books;
drop policy if exists books_delete_admin on public.books;
drop policy if exists admin_users_select_self on public.admin_users;

create or replace function public.is_admin_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_users au
    where lower(au.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.is_admin_user() to authenticated;

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

create policy admin_users_select_self
  on public.admin_users
  for select
  to authenticated
  using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

create policy shipments_select_admin
  on public.shipments
  for select
  to authenticated
  using (public.is_admin_user());

create policy shipments_insert_admin
  on public.shipments
  for insert
  to authenticated
  with check (public.is_admin_user());

create policy shipments_update_admin
  on public.shipments
  for update
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create policy shipments_delete_admin
  on public.shipments
  for delete
  to authenticated
  using (public.is_admin_user());

create policy books_select_admin
  on public.books
  for select
  to authenticated
  using (public.is_admin_user());

create policy books_insert_admin
  on public.books
  for insert
  to authenticated
  with check (public.is_admin_user());

create policy books_update_admin
  on public.books
  for update
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create policy books_delete_admin
  on public.books
  for delete
  to authenticated
  using (public.is_admin_user());

create or replace function public.lookup_seller_shipment(
  p_seller_name text,
  p_seller_phone text
)
returns table (
  id bigint,
  seller_name text,
  seller_phone text,
  pickup_date date,
  status text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    s.id,
    s.seller_name,
    s.seller_phone,
    s.pickup_date,
    s.status,
    s.created_at
  from public.shipments s
  where s.seller_name = btrim(coalesce(p_seller_name, ''))
    and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
      regexp_replace(btrim(coalesce(p_seller_phone, '')), '[^0-9]', '', 'g')
  order by s.created_at desc
  limit 1;
$$;

create or replace function public.lookup_seller_books(
  p_shipment_id bigint,
  p_seller_name text,
  p_seller_phone text
)
returns table (
  id bigint,
  shipment_id bigint,
  title text,
  option text,
  status text,
  price integer,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    b.id,
    b.shipment_id,
    b.title,
    b.option,
    b.status,
    b.price,
    b.created_at
  from public.books b
  join public.shipments s
    on s.id = b.shipment_id
  where b.shipment_id = p_shipment_id
    and s.seller_name = btrim(coalesce(p_seller_name, ''))
    and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
      regexp_replace(btrim(coalesce(p_seller_phone, '')), '[^0-9]', '', 'g')
  order by b.created_at asc;
$$;

grant execute on function public.lookup_seller_shipment(text, text) to anon, authenticated;
grant execute on function public.lookup_seller_books(bigint, text, text) to anon, authenticated;

-- Admin access must be managed explicitly through public.admin_users.
-- Do not bulk copy auth.users here because the auth pool includes both admin
-- accounts and public member accounts in the same Supabase project.

create table if not exists public.member_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  name text not null,
  nickname text null,
  phone text null,
  marketing_opt_in boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.guest_orders (
  id bigint generated always as identity primary key,
  order_number text not null unique,
  guest_name text not null,
  guest_email text not null,
  status text not null default 'payment_completed'
    check (status in ('payment_completed', 'preparing', 'shipped', 'delivered', 'cancelled')),
  order_summary text null,
  total_amount integer null check (total_amount is null or total_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_member_profiles_email_lower
  on public.member_profiles (lower(email));

create index if not exists idx_guest_orders_lookup
  on public.guest_orders (lower(guest_email), upper(order_number));

alter table public.member_profiles enable row level security;
alter table public.guest_orders enable row level security;

drop policy if exists member_profiles_select_self on public.member_profiles;
drop policy if exists member_profiles_update_self on public.member_profiles;
drop policy if exists guest_orders_select_public on public.guest_orders;

create policy member_profiles_select_self
  on public.member_profiles
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy member_profiles_update_self
  on public.member_profiles
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create or replace function public.touch_member_profile_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.touch_guest_order_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists member_profiles_set_updated_at on public.member_profiles;
create trigger member_profiles_set_updated_at
before update on public.member_profiles
for each row
execute function public.touch_member_profile_updated_at();

drop trigger if exists guest_orders_set_updated_at on public.guest_orders;
create trigger guest_orders_set_updated_at
before update on public.guest_orders
for each row
execute function public.touch_guest_order_updated_at();

create or replace function public.sync_member_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_name text;
  next_nickname text;
  next_phone text;
  next_marketing_opt_in boolean;
begin
  if new.email is null then
    return new;
  end if;

  if exists (
    select 1
    from public.admin_users au
    where lower(au.email) = lower(new.email)
  ) then
    delete from public.member_profiles
    where user_id = new.id;

    return new;
  end if;

  next_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), '');
  next_nickname := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'nickname', '')), '');
  next_phone := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone', '')), '');
  next_marketing_opt_in := coalesce(
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'marketing_opt_in', '')), '')::boolean,
    false
  );

  insert into public.member_profiles (user_id, email, name, nickname, phone, marketing_opt_in)
  values (
    new.id,
    lower(new.email),
    coalesce(next_name, split_part(lower(new.email), '@', 1)),
    coalesce(next_nickname, next_name, split_part(lower(new.email), '@', 1)),
    next_phone,
    next_marketing_opt_in
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    name = excluded.name,
    nickname = excluded.nickname,
    phone = excluded.phone,
    marketing_opt_in = excluded.marketing_opt_in,
    updated_at = now();

  -- Opportunistically link legacy shipment rows for the same member profile.
  update public.shipments s
  set user_id = new.id
  where s.user_id is null
    and s.seller_name = coalesce(next_name, split_part(lower(new.email), '@', 1))
    and next_phone is not null
    and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
      regexp_replace(next_phone, '[^0-9]', '', 'g');

  return new;
end;
$$;

drop trigger if exists on_auth_user_member_profile_sync on auth.users;
create trigger on_auth_user_member_profile_sync
after insert or update of email, raw_user_meta_data on auth.users
for each row
execute function public.sync_member_profile_from_auth();

delete from public.member_profiles mp
using public.admin_users au
where lower(mp.email) = lower(au.email);

insert into public.member_profiles (user_id, email, name, nickname, phone, marketing_opt_in)
select
  u.id,
  lower(u.email),
  coalesce(
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'name', '')), ''),
    split_part(lower(u.email), '@', 1)
  ),
  coalesce(
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'nickname', '')), ''),
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'name', '')), ''),
    split_part(lower(u.email), '@', 1)
  ),
  nullif(btrim(coalesce(u.raw_user_meta_data ->> 'phone', '')), ''),
  coalesce(
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'marketing_opt_in', '')), '')::boolean,
    false
  )
from auth.users u
where u.email is not null
  and not exists (
    select 1
    from public.admin_users au
    where lower(au.email) = lower(u.email)
  )
on conflict (user_id) do update
set
  email = excluded.email,
  name = excluded.name,
  nickname = excluded.nickname,
  phone = excluded.phone,
  marketing_opt_in = excluded.marketing_opt_in,
  updated_at = now();

create or replace function public.get_current_auth_account_role()
returns table (
  account_role text,
  user_id uuid,
  email text,
  name text,
  nickname text,
  phone text,
  marketing_opt_in boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with viewer as (
    select
      auth.uid() as user_id,
      lower(coalesce(auth.jwt() ->> 'email', '')) as email
  )
  select
    case
      when viewer.user_id is null then 'guest'
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = viewer.email
      ) then 'admin'
      when mp.user_id is not null then 'member'
      else 'unknown'
    end as account_role,
    viewer.user_id,
    coalesce(mp.email, viewer.email) as email,
    mp.name,
    mp.nickname,
    mp.phone,
    coalesce(mp.marketing_opt_in, false) as marketing_opt_in
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

create or replace function public.lookup_member_for_password_reset(
  p_name text,
  p_email text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.member_profiles mp
    where lower(mp.email) = lower(btrim(coalesce(p_email, '')))
      and regexp_replace(coalesce(mp.name, ''), '\s+', '', 'g')
        = regexp_replace(btrim(coalesce(p_name, '')), '\s+', '', 'g')
  );
$$;

create or replace function public.lookup_guest_order(
  p_guest_name text,
  p_guest_email text,
  p_order_number text
)
returns table (
  id bigint,
  order_number text,
  guest_name text,
  guest_email text,
  status text,
  order_summary text,
  total_amount integer,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    go.id,
    go.order_number,
    go.guest_name,
    go.guest_email,
    go.status,
    go.order_summary,
    go.total_amount,
    go.created_at
  from public.guest_orders go
  where lower(go.guest_email) = lower(btrim(coalesce(p_guest_email, '')))
    and regexp_replace(coalesce(go.guest_name, ''), '\s+', '', 'g')
      = regexp_replace(btrim(coalesce(p_guest_name, '')), '\s+', '', 'g')
    and upper(go.order_number) = upper(btrim(coalesce(p_order_number, '')))
  order by go.created_at desc
  limit 1;
$$;

grant execute on function public.lookup_member_for_password_reset(text, text) to anon, authenticated;
grant execute on function public.lookup_guest_order(text, text, text) to anon, authenticated;
grant execute on function public.get_current_auth_account_role() to authenticated;

create table if not exists public.member_shipping_addresses (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null,
  recipient_name text not null,
  recipient_phone text not null,
  postal_code text not null,
  address_line1 text not null,
  address_line2 text null,
  delivery_memo text null,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.member_settlement_accounts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  bank_name text not null,
  account_number text not null,
  account_holder text not null,
  is_default boolean not null default false,
  is_verified boolean not null default false,
  verified_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_member_shipping_addresses_user_id_created_at
  on public.member_shipping_addresses (user_id, created_at desc);

create unique index if not exists idx_member_shipping_addresses_default
  on public.member_shipping_addresses (user_id)
  where is_default;

create index if not exists idx_member_settlement_accounts_user_id_created_at
  on public.member_settlement_accounts (user_id, created_at desc);

create unique index if not exists idx_member_settlement_accounts_default
  on public.member_settlement_accounts (user_id)
  where is_default;

alter table public.member_shipping_addresses enable row level security;
alter table public.member_settlement_accounts enable row level security;

drop policy if exists member_shipping_addresses_select_self on public.member_shipping_addresses;
drop policy if exists member_shipping_addresses_insert_self on public.member_shipping_addresses;
drop policy if exists member_shipping_addresses_update_self on public.member_shipping_addresses;
drop policy if exists member_shipping_addresses_delete_self on public.member_shipping_addresses;
drop policy if exists member_settlement_accounts_select_self on public.member_settlement_accounts;
drop policy if exists member_settlement_accounts_insert_self on public.member_settlement_accounts;
drop policy if exists member_settlement_accounts_update_self on public.member_settlement_accounts;
drop policy if exists member_settlement_accounts_delete_self on public.member_settlement_accounts;

create policy member_shipping_addresses_select_self
  on public.member_shipping_addresses
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy member_shipping_addresses_insert_self
  on public.member_shipping_addresses
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy member_shipping_addresses_update_self
  on public.member_shipping_addresses
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy member_shipping_addresses_delete_self
  on public.member_shipping_addresses
  for delete
  to authenticated
  using (auth.uid() = user_id);

create policy member_settlement_accounts_select_self
  on public.member_settlement_accounts
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy member_settlement_accounts_insert_self
  on public.member_settlement_accounts
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy member_settlement_accounts_update_self
  on public.member_settlement_accounts
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy member_settlement_accounts_delete_self
  on public.member_settlement_accounts
  for delete
  to authenticated
  using (auth.uid() = user_id);

create or replace function public.touch_member_row_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists member_shipping_addresses_set_updated_at on public.member_shipping_addresses;
create trigger member_shipping_addresses_set_updated_at
before update on public.member_shipping_addresses
for each row
execute function public.touch_member_row_updated_at();

drop trigger if exists member_settlement_accounts_set_updated_at on public.member_settlement_accounts;
create trigger member_settlement_accounts_set_updated_at
before update on public.member_settlement_accounts
for each row
execute function public.touch_member_row_updated_at();

create or replace function public.get_member_dashboard_summary()
returns table (
  user_id uuid,
  email text,
  name text,
  nickname text,
  display_name text,
  phone text,
  marketing_opt_in boolean,
  shipping_address_count integer,
  default_shipping_address_id bigint,
  settlement_account_count integer,
  default_settlement_account_id bigint,
  shipment_count integer,
  recent_shipment_count integer,
  total_book_count integer,
  on_sale_book_count integer,
  settled_book_count integer,
  estimated_on_sale_value integer,
  estimated_settled_value integer,
  latest_shipment_created_at timestamptz,
  latest_shipment_pickup_date date,
  latest_shipment_status text
)
language sql
stable
security definer
set search_path = public
as $$
  with member as (
    select
      mp.user_id,
      mp.email,
      mp.name,
      mp.nickname,
      mp.phone,
      mp.marketing_opt_in
    from public.member_profiles mp
    where mp.user_id = auth.uid()
  ),
  address_stats as (
    select
      count(*)::integer as shipping_address_count,
      max(id) filter (where is_default) as default_shipping_address_id
    from public.member_shipping_addresses
    where user_id = auth.uid()
  ),
  account_stats as (
    select
      count(*)::integer as settlement_account_count,
      max(id) filter (where is_default) as default_settlement_account_id
    from public.member_settlement_accounts
    where user_id = auth.uid()
  ),
  shipment_stats as (
    select
      count(*)::integer as shipment_count,
      count(*) filter (where s.created_at >= now() - interval '30 days')::integer as recent_shipment_count,
      max(s.created_at) as latest_shipment_created_at,
      (array_agg(s.pickup_date order by s.created_at desc, s.id desc))[1] as latest_shipment_pickup_date,
      (array_agg(s.status order by s.created_at desc, s.id desc))[1] as latest_shipment_status
    from public.shipments s
    where s.user_id = auth.uid()
  ),
  book_stats as (
    select
      count(b.id)::integer as total_book_count,
      count(*) filter (where b.status = 'on_sale')::integer as on_sale_book_count,
      count(*) filter (where b.status = 'settled')::integer as settled_book_count,
      coalesce(sum(b.price) filter (where b.status = 'on_sale'), 0)::integer as estimated_on_sale_value,
      coalesce(sum(b.price) filter (where b.status = 'settled'), 0)::integer as estimated_settled_value
    from public.books b
    join public.shipments s
      on s.id = b.shipment_id
    where s.user_id = auth.uid()
  )
  select
    member.user_id,
    member.email,
    member.name,
    member.nickname,
    coalesce(nullif(btrim(member.nickname), ''), member.name) as display_name,
    member.phone,
    member.marketing_opt_in,
    address_stats.shipping_address_count,
    address_stats.default_shipping_address_id,
    account_stats.settlement_account_count,
    account_stats.default_settlement_account_id,
    shipment_stats.shipment_count,
    shipment_stats.recent_shipment_count,
    book_stats.total_book_count,
    book_stats.on_sale_book_count,
    book_stats.settled_book_count,
    book_stats.estimated_on_sale_value,
    book_stats.estimated_settled_value,
    shipment_stats.latest_shipment_created_at,
    shipment_stats.latest_shipment_pickup_date,
    shipment_stats.latest_shipment_status
  from member
  cross join address_stats
  cross join account_stats
  cross join shipment_stats
  cross join book_stats;
$$;

create or replace function public.get_member_recent_shipments(
  p_limit integer default 5
)
returns table (
  id bigint,
  pickup_date date,
  status text,
  created_at timestamptz,
  book_count integer,
  on_sale_book_count integer,
  settled_book_count integer,
  estimated_on_sale_value integer,
  estimated_settled_value integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    s.pickup_date,
    s.status,
    s.created_at,
    count(b.id)::integer as book_count,
    count(*) filter (where b.status = 'on_sale')::integer as on_sale_book_count,
    count(*) filter (where b.status = 'settled')::integer as settled_book_count,
    coalesce(sum(b.price) filter (where b.status = 'on_sale'), 0)::integer as estimated_on_sale_value,
    coalesce(sum(b.price) filter (where b.status = 'settled'), 0)::integer as estimated_settled_value
  from public.shipments s
  left join public.books b
    on b.shipment_id = s.id
  where s.user_id = auth.uid()
  group by s.id
  order by s.created_at desc, s.id desc
  limit greatest(1, least(coalesce(p_limit, 5), 20));
$$;

grant execute on function public.get_member_dashboard_summary() to authenticated;
grant execute on function public.get_member_recent_shipments(integer) to authenticated;

create or replace function public.set_member_default_shipping_address(
  p_address_id bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.member_shipping_addresses
  set is_default = false
  where user_id = auth.uid();

  update public.member_shipping_addresses
  set is_default = true
  where user_id = auth.uid()
    and id = p_address_id;

  if not found then
    raise exception 'Shipping address not found.';
  end if;
end;
$$;

create or replace function public.set_member_default_settlement_account(
  p_account_id bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.member_settlement_accounts
  set is_default = false
  where user_id = auth.uid();

  update public.member_settlement_accounts
  set is_default = true
  where user_id = auth.uid()
    and id = p_account_id;

  if not found then
    raise exception 'Settlement account not found.';
  end if;
end;
$$;

grant execute on function public.set_member_default_shipping_address(bigint) to authenticated;
grant execute on function public.set_member_default_settlement_account(bigint) to authenticated;

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

create or replace function public.list_admin_shipments(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  id bigint,
  seller_name text,
  seller_phone text,
  pickup_date date,
  status text,
  created_at timestamptz,
  book_count integer,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits,
      coalesce(cardinality(p_statuses), 0) as status_count
  ),
  filtered_shipments as (
    select
      s.id,
      s.seller_name,
      s.seller_phone,
      s.pickup_date,
      s.status,
      s.created_at,
      count(b.id)::integer as book_count
    from public.shipments s
    left join public.books b
      on b.shipment_id = s.id
    cross join params
    where public.is_admin_user()
      and (
        params.search_term = ''
        or s.seller_name ilike '%' || params.search_term || '%'
        or s.seller_phone ilike '%' || params.search_term || '%'
        or (
          params.search_digits <> ''
          and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') like '%' || params.search_digits || '%'
        )
        or s.id::text ilike '%' || params.search_term || '%'
      )
      and (
        params.status_count = 0
        or s.status = any(p_statuses)
      )
      and (
        p_from_date is null
        or s.pickup_date >= p_from_date
      )
      and (
        p_to_date is null
        or s.pickup_date <= p_to_date
      )
    group by
      s.id,
      s.seller_name,
      s.seller_phone,
      s.pickup_date,
      s.status,
      s.created_at
  )
  select
    filtered_shipments.id,
    filtered_shipments.seller_name,
    filtered_shipments.seller_phone,
    filtered_shipments.pickup_date,
    filtered_shipments.status,
    filtered_shipments.created_at,
    filtered_shipments.book_count,
    count(*) over()::integer as total_count
  from filtered_shipments
  order by
    filtered_shipments.pickup_date desc,
    filtered_shipments.created_at desc,
    filtered_shipments.id desc
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 20), 500));
$$;

grant execute on function public.list_admin_shipments(text, text[], date, date, integer, integer) to authenticated;
grant execute on function public.storefront_condition_grade_rank(text) to anon, authenticated;
grant execute on function public.storefront_product_group_key(text, text, text, text, text, integer, text) to anon, authenticated;
grant execute on function public.list_public_store_products(text[], text[], text[], integer[], text[], text, text, integer, integer) to anon, authenticated;
grant execute on function public.get_public_store_product_detail(bigint) to anon, authenticated;
grant execute on function public.list_public_store_books(text[], text[], text[], integer[], text[], text, text, integer, integer) to anon, authenticated;
grant execute on function public.get_public_store_book_detail(bigint) to anon, authenticated;
