create table if not exists public.admin_users (
  email text primary key,
  created_at timestamptz not null default now()
);

create index if not exists idx_admin_users_email_lower
  on public.admin_users (lower(email));

alter table public.admin_users enable row level security;

drop policy if exists shipments_select_public on public.shipments;
drop policy if exists shipments_insert_public on public.shipments;
drop policy if exists shipments_update_public on public.shipments;
drop policy if exists books_select_public on public.books;
drop policy if exists books_insert_public on public.books;
drop policy if exists books_update_public on public.books;

drop policy if exists shipments_select_admin on public.shipments;
drop policy if exists shipments_insert_admin on public.shipments;
drop policy if exists shipments_update_admin on public.shipments;
drop policy if exists books_select_admin on public.books;
drop policy if exists books_insert_admin on public.books;
drop policy if exists books_update_admin on public.books;
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
