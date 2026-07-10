-- 차단/해제 RPC 구버전 오버로드 제거 (어드민 차단 해제 불가 버그 수정)
--
-- 문제: 2026051308의 원본 시그니처(admin_unblock_member(uuid),
-- admin_block_member(uuid, text))를 20260525040333이 인자 추가 버전으로 교체할 때
-- CREATE OR REPLACE를 썼는데, 시그니처가 다르면 교체가 아니라 "오버로드 추가"가 된다.
-- → admin_unblock_member를 p_user_id만으로 호출하면 PostgREST가
--   두 후보(uuid) / (uuid, text) 중 선택 불가:
--   "Could not choose the best candidate function between ..."
-- 게다가 구버전에는 20260710170453의 auth 레벨 밴/해제 로직이 없어,
-- 구버전으로 해석되면 차단이 다시 "플래그만" 동작으로 퇴행한다.
--
-- 조치: 구버전 시그니처 2개를 명시적으로 drop. 현행 버전
-- (block: uuid,text,boolean / unblock: uuid,text — 밴 로직 포함)만 남긴다.

drop function if exists public.admin_unblock_member(uuid);
drop function if exists public.admin_block_member(uuid, text);
