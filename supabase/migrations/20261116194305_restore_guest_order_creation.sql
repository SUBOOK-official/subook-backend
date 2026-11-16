-- 2026-11-17 20261116193802_revoke_guest_order_creation 되돌림.
--
-- 그 migration은 비회원 구매를 전부 막았다. 뜻한 것은 "일성월심 학습지(앱 패키지 상품)만 회원 구매"였고,
-- 다른 교재는 비회원도 계속 살 수 있어야 한다. 원래대로 anon에게만 실행 권한을 돌려준다
-- (20260803061500_guest_orders.sql과 같은 상태: public·authenticated는 없음, anon만 있음).
-- 일성월심 학습지의 비회원 구매를 막는 것은 뒤따르는 migration에서 상품 단위로 한다.

grant execute on function public.create_guest_order(
  bigint[], integer[], text, text, text, text, text, text, text, text, text, boolean
) to anon;

grant execute on function public.create_guest_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, boolean
) to anon;
