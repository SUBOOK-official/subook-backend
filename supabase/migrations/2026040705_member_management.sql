alter table public.member_profiles
  add column if not exists nickname text null,
  add column if not exists marketing_opt_in boolean not null default false;

-- Backfill the nickname so the display name stays useful even before the user edits it.
update public.member_profiles
set nickname = coalesce(nullif(btrim(nickname), ''), name)
where nickname is null
   or btrim(nickname) = '';

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

create index if not exists idx_shipments_user_id_created_at
  on public.shipments (user_id, created_at desc);

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
on conflict (user_id) do update
set
  email = excluded.email,
  name = excluded.name,
  nickname = excluded.nickname,
  phone = excluded.phone,
  marketing_opt_in = excluded.marketing_opt_in,
  updated_at = now();

-- Use a unique seller name/phone match so the mypage summary can show legacy activity.
update public.shipments s
set user_id = matched.user_id
from (
  select s2.id as shipment_id, mp.user_id
  from public.shipments s2
  join public.member_profiles mp
    on mp.name = s2.seller_name
   and regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') =
     regexp_replace(s2.seller_phone, '[^0-9]', '', 'g')
  where mp.phone is not null
    and not exists (
      select 1
      from public.member_profiles mp2
      where mp2.name = s2.seller_name
        and regexp_replace(coalesce(mp2.phone, ''), '[^0-9]', '', 'g') =
          regexp_replace(s2.seller_phone, '[^0-9]', '', 'g')
        and mp2.user_id <> mp.user_id
    )
) matched
where s.id = matched.shipment_id
  and s.user_id is null;

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
