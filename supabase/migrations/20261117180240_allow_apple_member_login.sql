-- 2026-11-18 수북 회원 로그인 수단에 Apple 추가.
--
-- 까닭: 일성월심 앱이 수북 계정으로 로그인한다. 앱에 카카오 로그인을 두려면 App Store 규정상 Apple 로그인도 있어야 한다.
--
-- 하는 일: 가입 전 확인 함수(before_member_user_created)가 Apple을 카카오·구글과 같은 소셜 가입으로 받는다.
--   나머지 본문은 20261001091226_reject_duplicate_phone_signup.sql과 글자까지 같다.
--   · 이메일이 없는 계정은 지금처럼 거절한다(Apple은 실제 이메일이나 가려 주는 이메일을 준다).
--   · 소셜 가입은 인증 레코드만 먼저 생기고, 회원 프로필은 휴대폰 인증 뒤에 만들어진다(지금 규칙 그대로).
--     Apple 가입자는 카카오 번호 확인이 없으니 문자 인증(/auth/verify-phone)으로 간다.
-- 이 migration만으로는 아무도 Apple로 가입하지 못한다. Supabase 로그인 설정에서 Apple을 켜야 한다.
-- 롤백: 목록에서 'apple'을 뺀 정의로 되돌린다(Supabase에서 Apple을 먼저 끈다).

create or replace function public.before_member_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_email text:=lower(btrim(event->'user'->>'email')); v_provider text:=event->'user'->'app_metadata'->>'provider';
  v_id text:=event->'user'->'user_metadata'->>'signup_phone_id'; v_secret text:=event->'user'->'user_metadata'->>'signup_phone_secret';
begin
  if v_email is null or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','이메일이 있는 계정으로 가입해 주세요.'));
  end if;
  if v_provider in ('kakao','google','apple') then return '{}'::jsonb; end if;
  if v_provider<>'email' or v_id is null or v_id !~ '^[a-f0-9-]{36}$' or v_secret is null or length(v_secret)<>64 then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','회원가입 화면에서 휴대폰 인증을 먼저 완료해 주세요.'));
  end if;
  if not exists(select 1 from public.member_signup_phone_challenges where id=v_id::uuid and email=v_email
    and secret_hash=encode(extensions.digest(v_secret,'sha256'),'hex') and verified_at is not null and expires_at>now() and claimed_at is null) then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','휴대폰 인증이 만료됐습니다. 다시 인증해 주세요.'));
  end if;
  if exists(select 1 from public.member_signup_phone_challenges c where c.id=v_id::uuid and public._member_phone_conflicts(null,c.phone)) then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','이 전화번호로 가입된 계정이 있습니다. 기존 계정으로 로그인해 주세요.'));
  end if;
  return '{}'::jsonb;
end;
$$;
