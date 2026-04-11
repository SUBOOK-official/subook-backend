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
  next_email text;
  next_name text;
  next_nickname text;
  next_phone text;
  next_marketing_opt_in boolean := false;
  is_admin_email boolean := false;
begin
  if new.email is null then
    return new;
  end if;

  next_email := lower(new.email);

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
    updated_at = now()
  where lower(email) = next_email
    and user_id <> new.id;

  insert into public.member_profiles (user_id, email, name, nickname, phone, marketing_opt_in)
  values (
    new.id,
    next_email,
    coalesce(next_name, split_part(next_email, '@', 1)),
    coalesce(next_nickname, next_name, split_part(next_email, '@', 1)),
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

create or replace function public.check_member_email_availability(
  p_email text
)
returns table (
  normalized_email text,
  is_available boolean,
  account_role text
)
language sql
stable
security definer
set search_path = public
as $$
  with normalized as (
    select lower(nullif(btrim(p_email), '')) as email
  )
  select
    normalized.email as normalized_email,
    case
      when normalized.email is null then false
      when exists (
        select 1
        from auth.users u
        where lower(u.email) = normalized.email
      ) then false
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = normalized.email
      ) then false
      when exists (
        select 1
        from public.member_profiles mp
        where lower(mp.email) = normalized.email
      ) then false
      else true
    end as is_available,
    case
      when normalized.email is null then 'invalid'
      when exists (
        select 1
        from auth.users u
        where lower(u.email) = normalized.email
      ) then 'registered'
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = normalized.email
      ) then 'admin'
      when exists (
        select 1
        from public.member_profiles mp
        where lower(mp.email) = normalized.email
      ) then 'member'
      else 'available'
    end as account_role
  from normalized;
$$;

grant execute on function public.check_member_email_availability(text) to anon, authenticated;
