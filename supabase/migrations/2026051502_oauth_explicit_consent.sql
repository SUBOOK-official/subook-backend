-- OAuth 가입 시 약관 자동 동의 처리되던 문제 해결
--
-- 1) sync_member_profile_from_auth: OAuth provider면 terms/privacy/marketing_agreed_at
--    을 NULL로 두고, 명시적 메타데이터가 있을 때만 채움.
--    (이메일 가입은 raw_user_meta_data에 명시값을 PublicSignupPage가 세팅하므로 영향 없음.)
--
-- 2) complete_oauth_signup(p_marketing_opt_in boolean): OAuth 사용자가 약관 동의 페이지에서
--    호출. terms_agreed_at, privacy_agreed_at을 now()로 명시 기록.
--
-- 3) get_current_auth_account_role: 응답에 terms_agreed_at, privacy_agreed_at 추가
--    → 프론트 isAuthenticated 게이트에서 OAuth 동의 여부 검증 가능.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 0) 컬럼 존재 보장 (2026041206이 production에 부분 적용된 케이스 대응)
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.member_profiles
  add column if not exists terms_agreed_at timestamptz null,
  add column if not exists privacy_agreed_at timestamptz null,
  add column if not exists marketing_agreed_at timestamptz null,
  add column if not exists withdrawal_requested_at timestamptz null,
  add column if not exists withdrawal_scheduled_at timestamptz null,
  add column if not exists personal_data_erased_at timestamptz null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 트리거 수정 — OAuth provider인 경우 terms_agreed_at NULL 시작
-- ─────────────────────────────────────────────────────────────────────────────
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
  next_terms_agreed_at timestamptz;
  next_privacy_agreed_at timestamptz;
  next_marketing_agreed_at timestamptz;
  next_email_verified_at timestamptz;
  is_admin_email boolean := false;
  is_oauth_user boolean := false;
  v_meta_terms_text text;
  v_meta_privacy_text text;
  v_meta_marketing_text text;
begin
  next_email := lower(coalesce(nullif(btrim(new.email), ''), new.id::text || '@oauth.subook.local'));
  next_email_verified_at := new.email_confirmed_at;

  if exists (
    select 1
    from public.member_profiles mp
    where mp.user_id = new.id
      and mp.withdrawal_requested_at is not null
  ) then
    return new;
  end if;

  -- OAuth provider 판별
  is_oauth_user := new.raw_app_meta_data is not null
    and new.raw_app_meta_data ->> 'provider' is not null
    and new.raw_app_meta_data ->> 'provider' <> 'email';

  -- OAuth는 email_confirmed_at이 없어도 인증된 것으로 처리 (네이버/카카오 등)
  if next_email_verified_at is null and is_oauth_user then
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

  -- 명시 메타데이터에 동의 시각이 있을 때만 채움. 없으면 NULL.
  v_meta_terms_text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'terms_agreed_at', '')), '');
  v_meta_privacy_text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'privacy_agreed_at', '')), '');
  v_meta_marketing_text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'marketing_agreed_at', '')), '');

  if v_meta_terms_text is not null then
    next_terms_agreed_at := v_meta_terms_text::timestamptz;
  elsif is_oauth_user then
    -- OAuth는 명시 동의 전까지 NULL (complete_oauth_signup RPC에서 채움)
    next_terms_agreed_at := null;
  else
    -- 이메일 가입 시 메타데이터 누락 케이스 — 기존 behavior 유지
    next_terms_agreed_at := coalesce(new.created_at, now());
  end if;

  if v_meta_privacy_text is not null then
    next_privacy_agreed_at := v_meta_privacy_text::timestamptz;
  elsif is_oauth_user then
    next_privacy_agreed_at := null;
  else
    next_privacy_agreed_at := coalesce(new.created_at, now());
  end if;

  next_marketing_agreed_at := case
    when not next_marketing_opt_in then null
    when v_meta_marketing_text is not null then v_meta_marketing_text::timestamptz
    when is_oauth_user then null
    else coalesce(new.created_at, now())
  end;

  insert into public.member_profiles (
    user_id,
    email,
    name,
    nickname,
    phone,
    marketing_opt_in,
    terms_agreed_at,
    privacy_agreed_at,
    marketing_agreed_at,
    email_verified_at
  )
  values (
    new.id,
    next_email,
    coalesce(next_name, split_part(next_email, '@', 1)),
    coalesce(next_nickname, next_name, split_part(next_email, '@', 1)),
    next_phone,
    next_marketing_opt_in,
    next_terms_agreed_at,
    next_privacy_agreed_at,
    next_marketing_agreed_at,
    next_email_verified_at
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    name = excluded.name,
    nickname = excluded.nickname,
    phone = excluded.phone,
    marketing_opt_in = excluded.marketing_opt_in,
    terms_agreed_at = coalesce(public.member_profiles.terms_agreed_at, excluded.terms_agreed_at),
    privacy_agreed_at = coalesce(public.member_profiles.privacy_agreed_at, excluded.privacy_agreed_at),
    marketing_agreed_at = case
      when excluded.marketing_opt_in then coalesce(public.member_profiles.marketing_agreed_at, excluded.marketing_agreed_at)
      else null
    end,
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) complete_oauth_signup: OAuth 사용자의 명시적 약관 동의 저장
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.complete_oauth_signup(
  p_marketing_opt_in boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_now timestamptz := now();
  v_existing record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  -- 기존 profile 있는지 확인 (트리거가 이미 row 생성)
  select * into v_existing
  from public.member_profiles
  where user_id = v_user_id;

  if not found then
    raise exception 'Member profile not found. OAuth callback may not have completed.';
  end if;

  update public.member_profiles
  set
    terms_agreed_at = coalesce(terms_agreed_at, v_now),
    privacy_agreed_at = coalesce(privacy_agreed_at, v_now),
    marketing_opt_in = coalesce(p_marketing_opt_in, false),
    marketing_agreed_at = case
      when coalesce(p_marketing_opt_in, false) then coalesce(marketing_agreed_at, v_now)
      else null
    end,
    updated_at = v_now
  where user_id = v_user_id;

  return jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'terms_agreed_at', coalesce(v_existing.terms_agreed_at, v_now),
    'privacy_agreed_at', coalesce(v_existing.privacy_agreed_at, v_now),
    'marketing_opt_in', coalesce(p_marketing_opt_in, false)
  );
end;
$$;

grant execute on function public.complete_oauth_signup(boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) get_current_auth_account_role: 응답에 terms_agreed_at 추가
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.get_current_auth_account_role();

create or replace function public.get_current_auth_account_role()
returns table (
  account_role text,
  user_id uuid,
  email text,
  name text,
  nickname text,
  phone text,
  marketing_opt_in boolean,
  email_verified_at timestamptz,
  terms_agreed_at timestamptz,
  privacy_agreed_at timestamptz,
  withdrawal_requested_at timestamptz,
  withdrawal_scheduled_at timestamptz,
  personal_data_erased_at timestamptz
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
      when mp.personal_data_erased_at is not null then 'withdrawn'
      when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
      when mp.user_id is not null then 'member'
      else 'unknown'
    end as account_role,
    viewer.user_id,
    coalesce(mp.email, viewer.email) as email,
    mp.name,
    mp.nickname,
    mp.phone,
    coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
    mp.email_verified_at,
    mp.terms_agreed_at,
    mp.privacy_agreed_at,
    mp.withdrawal_requested_at,
    mp.withdrawal_scheduled_at,
    mp.personal_data_erased_at
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

grant execute on function public.get_current_auth_account_role() to authenticated;

commit;
