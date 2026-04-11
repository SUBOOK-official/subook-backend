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

-- Admin access must be managed explicitly through public.admin_users.
-- Do not bulk copy auth.users here because the auth pool includes both admin
-- accounts and public member accounts in the same Supabase project.
