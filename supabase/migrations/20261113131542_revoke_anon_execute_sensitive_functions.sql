-- 2026-11-13 보안 감사 긴급 조치: 민감 함수의 익명·일반 로그인 실행 권한 회수
--
-- 배경: Supabase 기본 권한(default privileges)은 새 함수에 anon·authenticated·service_role
--       EXECUTE를 역할별로 따로 부여한다. 과거 마이그레이션은 public·authenticated만 회수하고
--       anon을 빠뜨리거나 아예 회수하지 않아, 아래 함수들이 사이트 공개 키(anon)만으로
--       호출 가능했다(운영에서 실측 확인).
--   1) get_account_encryption_key / decrypt_account_number / encrypt_account_number
--      — 계좌번호 암호화 키 반환·복호화. 내부 SECURITY DEFINER 함수만 써야 한다.
--   2) admin_list_pending_restock_alerts — 재입고 대기 회원의 이메일·전화·이름 반환 (크론 전용)
--      auto_confirm_delivered_orders     — 구매확정 주문의 셀러 이름·전화·회원 ID 반환 (크론 전용)
--   3) admin_create_member_notification  — 임의 회원에게 알림(제목·본문·링크) 삽입 (서버리스 전용)
--
-- 영향: 호출부는 전부 service_role(admin-web 서버리스: auto-confirm-orders / notify-restock /
--       send-notification)이라 정상 기능 변화 없음. 암호화 함수를 호출하는 DB 함수 8개는 모두
--       SECURITY DEFINER(소유자 postgres)라 내부 호출이 그대로 동작한다.
-- 롤백: 아래 대상에 grant execute ... to anon, authenticated 재실행 (권장하지 않음).
-- 후속: 암호화 키는 노출 이력이 있으므로 별도 작업으로 교체·재암호화한다.

-- 1) 계좌번호 암호화 키·암복호화
revoke execute on function public.get_account_encryption_key() from public, anon, authenticated;
revoke execute on function public.decrypt_account_number(bytea) from public, anon, authenticated;
revoke execute on function public.encrypt_account_number(text) from public, anon, authenticated;

-- 2) 개인정보를 반환하는 크론 전용 함수
revoke execute on function public.admin_list_pending_restock_alerts(integer) from public, anon, authenticated;
revoke execute on function public.auto_confirm_delivered_orders() from public, anon, authenticated;

-- 3) 회원 알림 삽입 (서버리스 전용)
revoke execute on function public.admin_create_member_notification(uuid, text, text, text, text, text, bigint)
  from public, anon, authenticated;

-- 서버 호출 경로 보장 (이미 부여돼 있어도 멱등)
grant execute on function public.admin_list_pending_restock_alerts(integer) to service_role;
grant execute on function public.auto_confirm_delivered_orders() to service_role;
grant execute on function public.admin_create_member_notification(uuid, text, text, text, text, text, bigint)
  to service_role;
