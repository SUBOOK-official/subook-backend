-- 교재 등록 담당 계정이 로그인 직후 "관리자 권한을 확인하지 못했습니다"로 막히던 문제 (2026-11-16)
--
-- 원인: PostgREST 요청마다 먼저 도는 관문 enforce_member_identity_request()
--       (authenticator의 pgrst.db_pre_request, 1번호 1계정 정책 — 20261001060422)이
--       "관리자도 아니고 휴대폰 인증도 안 한 계정"의 요청을 PT403으로 막는다.
--       등록 담당(role=intake)은 허용한 등록 RPC 요청에서만 is_admin_user()=true라서,
--       로그인 직후 화면이 부르는 get_admin_access(권한 조회)는 이 관문에서 403이 됐다.
--       (20261116030246 검증은 함수를 직접 불러서 이 관문을 거치지 않았다.)
--
-- 변경: 관문의 "휴대폰 인증 없이도 부를 수 있는 RPC" 목록에 rpc/get_admin_access 하나를 추가한다.
--       get_admin_access는 부른 사람 자신의 역할({"role": admin|intake|null})만 돌려주므로
--       일반 회원에게 열려도 새로 드러나는 정보가 없다(실행 권한은 로그인 계정에만 있다).
--       그 밖의 본문·권한·순서는 20261001060422 정의 그대로다.
--       등록 담당이 그 밖의 요청을 보내면 여전히 이 관문에서 막힌다(등록 RPC는 is_admin_user()로 통과).
--
-- 롤백: 목록에서 'rpc/get_admin_access'를 뺀 20261001060422 정의로 되돌린다.

begin;

create or replace function public.enforce_member_identity_request() returns void
language plpgsql security definer set search_path='' as $$
declare v_path text:=ltrim(coalesce(current_setting('request.path',true),''),'/');
begin
  if auth.uid() is null or auth.role()='service_role' then return; end if;
  -- 운영자 콘솔은 회원 전화 정책과 독립적이다.
  if public.is_admin_user() then return; end if;
  if v_path in ('rpc/get_member_identity_policy','rpc/get_my_member_identity','rpc/get_current_auth_account_role',
    'rpc/is_admin_user','rpc/verify_phone_otp','rpc/start_member_account_merge','rpc/get_member_account_merge',
    'rpc/prove_member_account_merge','rpc/complete_member_account_merge','rpc/attach_signup_referral','rpc/get_signup_referral_offer',
    -- 관리자 화면의 권한 조회 — 등록 담당 계정은 휴대폰 인증이 없으므로 여기서 열어 준다
    'rpc/get_admin_access') then return; end if;
  if public.member_identity_is_ready() then return; end if;
  raise sqlstate 'PT403' using message='휴대폰 인증 또는 계정 통합을 완료해 주세요.';
end;
$$;

commit;
