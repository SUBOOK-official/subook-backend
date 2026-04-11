alter table public.member_profiles
  add column if not exists nickname text null,
  add column if not exists marketing_opt_in boolean not null default false;

update public.member_profiles
set nickname = coalesce(nullif(btrim(nickname), ''), name)
where nickname is null
   or btrim(nickname) = '';

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
