-- 2026-11-13 보안 감사 후속: 회원이 자기 프로필에서 직접 수정할 수 있는 컬럼 제한
--
-- 문제: member_profiles_update_self 정책(auth.uid() = user_id)에 테이블 전체 UPDATE 권한이
--       붙어 있어, 로그인한 회원이 REST로 자기 행의 모든 컬럼을 바꿀 수 있었다.
--       보호 트리거(guard_member_phone_fields)는 verified_phone·phone_verified_at만 막는다.
--   · is_blocked / blocked_at / block_reason — 차단 플래그 직접 해제
--   · email — 운영진 이메일로 바꿔 admin_block_member의 운영진 보호 가드에 걸리게 함(차단 회피)
--   · personal_data_erased_at — 탈퇴 절차 없이 전화번호 인증 해제 트리거 실행
--   · terms_agreed_at / privacy_agreed_at / email_verified_at / withdrawal_* — 동의·인증·탈퇴 기록 조작
--
-- 수정: 테이블 단위 UPDATE를 회수하고, 프론트가 실제로 직접 쓰는 4개 컬럼만 허용한다
--       (public-web memberPortal.js 프로필 저장: name, nickname, phone, marketing_opt_in).
--       그 외 컬럼은 기존대로 SECURITY DEFINER RPC·트리거(소유자 권한)로만 바뀐다.
--       새 컬럼은 기본적으로 직접 수정 불가 — 필요하면 여기에 명시적으로 추가한다.
-- 영향: SELECT·RLS 정책·RPC 변화 없음. updated_at은 BEFORE 트리거가 채우므로 권한 불필요.
-- 롤백: grant update on table public.member_profiles to authenticated;

revoke update on table public.member_profiles from anon, authenticated;
grant update (name, nickname, phone, marketing_opt_in) on table public.member_profiles to authenticated;
