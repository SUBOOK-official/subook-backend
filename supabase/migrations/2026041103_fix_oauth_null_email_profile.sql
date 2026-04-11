-- OAuth 사용자(네이버 등)가 email 없이 가입할 때 member_profiles 생성이 누락되는 문제 수정
-- 원인: sync_member_profile_from_auth 트리거가 email is null이면 early return

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
  -- OAuth 사용자는 email이 null일 수 있음 → 플레이스홀더 사용
  next_email := lower(coalesce(nullif(btrim(new.email), ''), new.id::text || '@oauth.subook.local'));
  next_email_verified_at := new.email_confirmed_at;

  -- OAuth 사용자(email_confirmed_at 없지만 provider가 email이 아닌 경우)는 자동 인증 처리
  if next_email_verified_at is null
    and new.raw_app_meta_data is not null
    and new.raw_app_meta_data ->> 'provider' is not null
    and new.raw_app_meta_data ->> 'provider' <> 'email'
  then
    next_email_verified_at := coalesce(new.email_confirmed_at, new.created_at, now());
  end if;

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

-- 기존 OAuth 사용자 중 member_profiles가 없는 경우 백필
insert into public.member_profiles (user_id, email, name, nickname, phone, marketing_opt_in, email_verified_at)
select
  u.id,
  lower(coalesce(nullif(btrim(u.email), ''), u.id::text || '@oauth.subook.local')),
  coalesce(
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'name', '')), ''),
    'User'
  ),
  coalesce(
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'nickname', '')), ''),
    nullif(btrim(coalesce(u.raw_user_meta_data ->> 'name', '')), ''),
    'User'
  ),
  nullif(btrim(coalesce(u.raw_user_meta_data ->> 'phone', '')), ''),
  false,
  coalesce(u.email_confirmed_at, u.created_at, now())
from auth.users u
where not exists (select 1 from public.member_profiles mp where mp.user_id = u.id)
  and not exists (
    select 1 from public.admin_users au
    where lower(au.email) = lower(coalesce(u.email, ''))
  )
on conflict (user_id) do nothing;
