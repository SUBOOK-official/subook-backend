-- 계정 정책 확장 (2026-07-10): admin/member 상호배타 폐지 → dual-role 허용
--
-- 배경: admin-web과 public-web이 같은 Supabase Auth 프로젝트를 공유하는데,
--   (1) sync_member_profile_from_auth 트리거가 admin 이메일의 member_profiles를 삭제하고
--   (2) get_current_auth_account_role이 admin_users 매치를 최우선으로 'admin' 반환하여
--   관리자 이메일은 public-web 로그인이 항상 차단됐다. (identity linking으로 구글 연결은
--   되는데 입장 불가 — "관리자 계정은 admin.subook.kr에서 로그인해 주세요")
--
-- 변경: 한 계정이 관리자이면서 동시에 일반 회원일 수 있다 (이메일 = 사람, 1인 1계정 정책의 연장).
--   - public-web: member_profiles 기준으로 판별 (관리자도 회원 프로필 있으면 'member')
--   - admin-web: 기존대로 is_admin_user()(admin_users 멤버십)로 판별 — 이 마이그레이션과 무관
--   - 관리자 권한 RLS/RPC는 전부 admin_users 멤버십 기준이라 보안 경계 변화 없음

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 트리거: admin 이메일의 member_profiles 삭제/생성스킵 로직 제거
--    (2026051502 버전에서 is_admin_email 분기만 걷어냄 — 나머지 동작 동일)
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
-- 2) get_current_auth_account_role: member 프로필 우선 판별 + is_admin 별도 컬럼
--    (반환 컬럼 추가라 drop 후 재생성 필요. 기존 프론트는 추가 컬럼을 무시하므로 안전)
-- ─────────────────────────────────────────────────────────────────────────────
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
  email_verified_at timestamptz,
  terms_agreed_at timestamptz,
  privacy_agreed_at timestamptz,
  withdrawal_requested_at timestamptz,
  withdrawal_scheduled_at timestamptz,
  personal_data_erased_at timestamptz,
  is_admin boolean
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
      when mp.personal_data_erased_at is not null then 'withdrawn'
      when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
      when mp.user_id is not null then 'member'
      -- member 프로필이 아직 없는 관리자 (아래 백필 + 트리거로 사실상 과도기 케이스)
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = viewer.email
      ) then 'admin'
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
    mp.personal_data_erased_at,
    exists (
      select 1
      from public.admin_users au
      where lower(au.email) = viewer.email
    ) as is_admin
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

grant execute on function public.get_current_auth_account_role() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 기존 관리자 계정 백필 — 회원 프로필 생성 (약관 동의는 NULL로 두어
--    public-web 첫 이용 시 가입 마무리(약관 동의) 페이지를 거치게 함)
--    idempotent: 이미 프로필 있으면 건드리지 않음
-- ─────────────────────────────────────────────────────────────────────────────
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
select
  u.id,
  lower(u.email),
  coalesce(nullif(btrim(u.raw_user_meta_data ->> 'name'), ''), split_part(lower(u.email), '@', 1)),
  coalesce(
    nullif(btrim(u.raw_user_meta_data ->> 'nickname'), ''),
    nullif(btrim(u.raw_user_meta_data ->> 'name'), ''),
    split_part(lower(u.email), '@', 1)
  ),
  nullif(btrim(u.raw_user_meta_data ->> 'phone'), ''),
  false,
  null,
  null,
  null,
  coalesce(u.email_confirmed_at, u.created_at)
from auth.users u
join public.admin_users au on lower(au.email) = lower(u.email)
where u.deleted_at is null
  and u.email is not null
on conflict (user_id) do nothing;

commit;
