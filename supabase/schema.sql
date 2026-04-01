-- Subook seller mini site schema

create extension if not exists pgcrypto;

create table if not exists public.shipments (
  id bigint generated always as identity primary key,
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
  status text not null default 'on_sale' check (status in ('on_sale', 'settled')),
  price integer null check (price is null or price >= 0),
  created_at timestamptz not null default now()
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
  phone text null,
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
  next_phone text;
begin
  if new.email is null then
    return new;
  end if;

  next_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), '');
  next_phone := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone', '')), '');

  insert into public.member_profiles (user_id, email, name, phone)
  values (
    new.id,
    lower(new.email),
    coalesce(next_name, split_part(lower(new.email), '@', 1)),
    next_phone
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    name = excluded.name,
    phone = excluded.phone,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_member_profile_sync on auth.users;
create trigger on_auth_user_member_profile_sync
after insert or update of email, raw_user_meta_data on auth.users
for each row
execute function public.sync_member_profile_from_auth();

insert into public.member_profiles (user_id, email, name, phone)
select
  u.id,
  lower(u.email),
  coalesce(
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'name', '')), ''),
    split_part(lower(u.email), '@', 1)
  ),
  nullif(btrim(coalesce(u.raw_user_meta_data ->> 'phone', '')), '')
from auth.users u
where u.email is not null
on conflict (user_id) do update
set
  email = excluded.email,
  name = excluded.name,
  phone = excluded.phone,
  updated_at = now();

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
