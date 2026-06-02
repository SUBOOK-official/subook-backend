-- BUG FIX: confirm_member_purchase 에 authenticated EXECUTE 권한 부여.
--
-- confirm_member_purchase(p_order_id bigint)는 2026041202에서 생성됐지만 어떤
-- 마이그레이션에서도 `grant execute ... to authenticated`가 없었다. 이 프로젝트는
-- 함수 default(public) execute가 revoke된 Supabase 셋업이라, 권한 없는 함수를
-- PostgREST가 404로 숨긴다 → 로그인 구매자가 "구매확정"을 눌러도 confirm_member_purchase
-- 호출이 404로 실패하고 주문이 배송완료에 머문다. (QA 크롬 라이브에서 재현)
-- service_role은 grant를 우회하므로 함수 자체는 정상 동작(P0001 raise 확인됨).
--
-- cancel_member_order는 2026051501에서 grant가 있으나, 드리프트 대비 방어적으로 함께 멱등 grant.
-- grant는 비파괴적이며 이미 부여돼 있어도 안전하다.

grant execute on function public.confirm_member_purchase(bigint) to authenticated;
grant execute on function public.cancel_member_order(bigint) to authenticated;
