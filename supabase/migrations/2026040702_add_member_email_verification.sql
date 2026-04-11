alter table public.member_profiles
  add column if not exists nickname text null,
  add column if not exists marketing_opt_in boolean not null default false,
  add column if not exists email_verified_at timestamptz null;

update public.member_profiles mp
set email_verified_at = coalesce(mp.email_verified_at, u.email_confirmed_at)
from auth.users u
where u.id = mp.user_id
  and u.email_confirmed_at is not null
  and mp.email_verified_at is null;

create or replace function public.sync_member_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_email text;
  next_name text;
  next_nickname text;
  next_phone text;
  next_marketing_opt_in boolean := false;
  next_email_verified_at timestamptz;
  is_admin_email boolean := false;
begin
  if new.email is null then
    return new;
  end if;

  next_email := lower(new.email);
  next_email_verified_at := new.email_confirmed_at;

  if to_regclass('public.admin_users') is not null then
    select exists (
      select 1
      from public.admin_users au
      where lower(au.email) = next_email
    )
    into is_admin_email;
  end if;

  if is_admin_email then
    delete from public.member_profiles
    where user_id = new.id
       or lower(email) = next_email;

    return new;
  end if;

  next_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), '');
  next_nickname := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'nickname', '')), '');
  next_phone := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone', '')), '');
  next_marketing_opt_in := case lower(coalesce(new.raw_user_meta_data ->> 'marketing_opt_in', ''))
    when 'true' then true
    when '1' then true
    when 'yes' then true
    when 'on' then true
    else false
  end;

  update public.member_profiles
  set
    user_id = new.id,
    email = next_email,
    name = coalesce(next_name, split_part(next_email, '@', 1)),
    nickname = coalesce(next_nickname, next_name, split_part(next_email, '@', 1)),
    phone = next_phone,
    marketing_opt_in = next_marketing_opt_in,
    email_verified_at = coalesce(public.member_profiles.email_verified_at, next_email_verified_at),
    updated_at = now()
  where lower(email) = next_email
    and user_id <> new.id;

  insert into public.member_profiles (user_id, email, name, nickname, phone, marketing_opt_in, email_verified_at)
  values (
    new.id,
    next_email,
    coalesce(next_name, split_part(next_email, '@', 1)),
    coalesce(next_nickname, next_name, split_part(next_email, '@', 1)),
    next_phone,
    next_marketing_opt_in,
    next_email_verified_at
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    name = excluded.name,
    nickname = excluded.nickname,
    phone = excluded.phone,
    marketing_opt_in = excluded.marketing_opt_in,
    email_verified_at = case
      when public.member_profiles.email = excluded.email
        then coalesce(public.member_profiles.email_verified_at, excluded.email_verified_at)
      else excluded.email_verified_at
    end,
    updated_at = now();

  begin
    if next_phone is not null and to_regclass('public.shipments') is not null then
      update public.shipments s
      set user_id = new.id
      where s.user_id is null
        and s.seller_name = coalesce(next_name, split_part(next_email, '@', 1))
        and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
          regexp_replace(next_phone, '[^0-9]', '', 'g');
    end if;
  exception
    when undefined_table or undefined_column then
      null;
  end;

  return new;
end;
$$;

drop trigger if exists on_auth_user_member_profile_sync on auth.users;
create trigger on_auth_user_member_profile_sync
after insert or update of email, raw_user_meta_data, email_confirmed_at on auth.users
for each row
execute function public.sync_member_profile_from_auth();

insert into public.member_profiles (user_id, email, name, nickname, phone, marketing_opt_in, email_verified_at)
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
  ),
  u.email_confirmed_at
from auth.users u
where u.email is not null
on conflict (user_id) do update
set
  email = excluded.email,
  name = excluded.name,
  nickname = excluded.nickname,
  phone = excluded.phone,
  marketing_opt_in = excluded.marketing_opt_in,
  email_verified_at = case
    when public.member_profiles.email = excluded.email
      then coalesce(public.member_profiles.email_verified_at, excluded.email_verified_at)
    else excluded.email_verified_at
  end,
  updated_at = now();

drop function if exists public.get_current_auth_account_role();

create function public.get_current_auth_account_role()
returns table (
  account_role text,
  user_id uuid,
  email text,
  name text,
  nickname text,
  phone text,
  marketing_opt_in boolean,
  email_verified_at timestamptz
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
    coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
    mp.email_verified_at
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

grant execute on function public.get_current_auth_account_role() to authenticated;

create or replace function public.complete_member_email_verification()
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  verified_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  update public.member_profiles
  set
    email_verified_at = coalesce(email_verified_at, now()),
    updated_at = now()
  where user_id = auth.uid()
  returning email_verified_at into verified_at;

  if verified_at is null then
    raise exception 'MEMBER_PROFILE_NOT_FOUND';
  end if;

  return verified_at;
end;
$$;

grant execute on function public.complete_member_email_verification() to authenticated;
