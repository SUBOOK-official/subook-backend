-- 계정 정책(2026-07-10 확정): 인증된 동일 이메일 = 1인 1계정.
-- Supabase automatic identity linking이 같은(인증된) 이메일의 카카오/구글/이메일 로그인을
-- 한 계정으로 묶는다. 남는 혼란 케이스(소셜 전용 계정의 비밀번호 로그인 시도, 중복 이메일
-- 재가입 시도)에서 "가입했던 수단"을 안내하기 위한 RPC를 추가한다.

-- 1) 이메일로 가입 수단(provider 목록)만 조회하는 RPC.
--    반환값은 provider 문자열 배열뿐 — 이름/전화 등 PII는 노출하지 않는다.
--    (이메일 존재 여부 자체는 기존 check_member_email_availability가 이미 노출하는 정보)
create or replace function public.get_member_auth_providers(
  p_email text
)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct i.provider order by i.provider), array[]::text[])
  from auth.users u
  join auth.identities i on i.user_id = u.id
  join public.member_profiles mp on mp.user_id = u.id
  where lower(u.email) = lower(nullif(btrim(p_email), ''))
    and u.deleted_at is null;
$$;

grant execute on function public.get_member_auth_providers(text) to anon, authenticated;

-- 2) check_member_email_availability의 account_role CASE 순서 수정.
--    기존엔 auth.users 체크('registered')가 최상단이라 'admin'/'member' 분기가 도달 불가 —
--    모든 회원이 auth.users에 존재하므로 가입 화면에서 기존 회원 이메일이 항상
--    "사용할 수 없는 이메일"(unavailable)로만 안내되고 "이미 가입된 이메일 + 로그인하기"
--    안내(state=duplicate)가 뜨지 않던 버그. is_available 판정(boolean)은 변경 없음.
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
        from public.admin_users au
        where lower(au.email) = normalized.email
      ) then 'admin'
      when exists (
        select 1
        from public.member_profiles mp
        where lower(mp.email) = normalized.email
      ) then 'member'
      when exists (
        select 1
        from auth.users u
        where lower(u.email) = normalized.email
      ) then 'registered'
      else 'available'
    end as account_role
  from normalized;
$$;

grant execute on function public.check_member_email_availability(text) to anon, authenticated;
