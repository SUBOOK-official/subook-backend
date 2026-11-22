-- 관리자 회원 화면: 회원이 지금 로그인할 수 있는 상태인지 읽기 (2026-11-22)
--
-- 배경: 일성월심 앱은 수북 계정으로 로그인한다. 앱 서버는 로그인 때 그 회원의
--       get_current_auth_account_role()(회원·차단·탈퇴)과 get_my_member_identity()(휴대폰 인증)를 보고,
--       정상 회원이고 휴대폰 인증까지 마친 계정만 받는다.
--       운영진이 회원 화면에서 앱 교재를 미리 등록할 때 "이 회원이 앱에 로그인할 수 있는지"를 알려 주려면
--       같은 두 가지를 관리자도 읽을 수 있어야 한다.
--       member_phone_identities · member_account_merges는 RLS로 잠겨 있어 화면이 직접 읽지 못하고,
--       member_profiles.phone_verified_at은 1번호 1계정 전환 전의 값이라 기준이 아니다.
--       get_admin_member_detail()은 차단·탈퇴 여부를 돌려주지 않는다.
--
-- 변경: get_admin_member_login_state(p_user_id) 추가. 한 회원에 대해
--         account_status   active / blocked / withdrawal_pending / withdrawn (list_admin_members와 같은 순서),
--                          회원 프로필이 없으면 missing
--         identity_enabled 1번호 1계정 정책이 켜져 있는지(꺼져 있으면 인증 없이도 회원이다)
--         identity_status  merged / verified / unverified (get_my_member_identity와 같은 순서)
--         verified_at, merged_into(통합된 대표 계정)
--       을 돌려준다. 관리자(is_admin_user())만 부를 수 있다. 전화번호는 돌려주지 않는다.
--       기존 함수·표·권한은 바꾸지 않는다.
--
-- 롤백: drop function public.get_admin_member_login_state(uuid);

begin;

create or replace function public.get_admin_member_login_state(p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_account text; v_enabled boolean; v_target uuid; v_verified_at timestamptz;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if p_user_id is null then raise exception 'Member id is required'; end if;
  select case
      when mp.personal_data_erased_at is not null then 'withdrawn'
      when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
      when coalesce(mp.is_blocked,false) then 'blocked'
      else 'active'
    end into v_account
    from public.member_profiles mp where mp.user_id=p_user_id;
  select enabled into v_enabled from public.member_identity_policy where singleton;
  select target_user_id into v_target from public.member_account_merges where source_user_id=p_user_id;
  select verified_at into v_verified_at from public.member_phone_identities where user_id=p_user_id;
  return jsonb_build_object(
    'account_status',coalesce(v_account,'missing'),
    'identity_enabled',coalesce(v_enabled,false),
    'identity_status',case when v_target is not null then 'merged' when v_verified_at is not null then 'verified' else 'unverified' end,
    'verified_at',v_verified_at,
    'merged_into',v_target);
end;
$$;

comment on function public.get_admin_member_login_state(uuid) is
  '관리자 회원 화면용: 한 회원의 계정 상태(정상·차단·탈퇴)와 휴대폰 인증 상태(verified/unverified/merged). 전화번호는 담지 않는다.';

revoke all on function public.get_admin_member_login_state(uuid) from public, anon, authenticated;
grant execute on function public.get_admin_member_login_state(uuid) to authenticated, service_role;

commit;
