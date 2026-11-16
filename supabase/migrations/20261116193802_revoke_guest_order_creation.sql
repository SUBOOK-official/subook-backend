-- 2026-11-17 비회원 구매 종료: 주문은 회원만 할 수 있다.
--
-- 20260803061500_guest_orders.sql이 연 비회원 주문 생성 RPC 두 개의 익명 실행 권한을 거둔다.
--   create_guest_order               — 무통장 비회원 주문 생성
--   create_guest_pg_checkout_session — 카드 비회원 결제 세션 생성
-- 두 함수는 anon에게만 열려 있었다(public·authenticated는 처음부터 revoke). 권한을 거두면 아무도 부를 수 없다.
--
-- 그대로 두는 것:
--   · finalize_pg_checkout_session(service_role 전용) — 이 migration 직전에 카드 결제창을 연 비회원의 결제는 끝까지 처리된다.
--   · get_guest_order 등 조회·취소 — 이미 받은 비회원 주문(orders.user_id is null)은 주문번호+휴대폰으로 계속 조회한다.
--   · 함수 본문·테이블 — 지우지 않는다.
-- 화면: public-web의 GUEST_CHECKOUT_OPEN=false(로그인 관문에서 "비회원으로 주문하기"를 내지 않는다)와 짝이다.
-- 롤백: 아래 두 줄을 grant execute ... to anon 으로 다시 실행하고 GUEST_CHECKOUT_OPEN을 true로 바꾼다.

revoke execute on function public.create_guest_order(
  bigint[], integer[], text, text, text, text, text, text, text, text, text, boolean
) from public, anon, authenticated;

revoke execute on function public.create_guest_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, boolean
) from public, anon, authenticated;
