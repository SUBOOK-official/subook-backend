-- 2026-11-13 보안 감사 후속: 내부·크론 전용 운영 함수의 익명·일반 로그인 실행 권한 회수
--
-- 20261113131542와 같은 원인(새 함수에 anon·authenticated EXECUTE가 역할별로 따로 부여됨)으로
-- 아래 함수들이 사이트 공개 키만으로 호출 가능했다. 전부 본문에 호출자 검사가 없다.
--   admin_mark_restock_notified       — 재입고 알림을 '발송됨'으로 표시 (알림 무력화 가능)
--   create_settlements_for_order      — 정산 생성
--   expire_unpaid_orders / expire_old_coupons — 만료 배치
--   sweep_missing_ai_summaries / request_ai_summary_generation — AI 요약 생성 요청(비용 발생)
--   generate_order_number / generate_pickup_request_number — 채번(주문 건수 노출)
--   refresh_storefront_product_status — 상품 상태 재계산
--   lookup_guest_order                — 구 비회원 주문 조회(현재 호출부 없음)
--
-- 영향 확인(2026-11-13 운영 DB·코드 대조):
--   · 클라이언트 호출부는 admin-web 서버리스 크론(service_role)뿐이거나 없음.
--   · 이 함수들을 부르는 DB 함수·트리거 함수는 전부 SECURITY DEFINER(소유자 postgres),
--     pg_cron 잡도 postgres로 실행 → 내부 호출은 그대로 동작.
--   · 정책·뷰·컬럼 기본값에서의 사용 없음.
-- 의도적으로 남긴 것: get_books_pricing_for_order(주문서에서 사용, 공개 가격 정보),
--   pickup_request_root_id(사용처 확인 불충분).
-- 롤백: 대상 함수에 grant execute ... to anon, authenticated 재실행 (권장하지 않음).

revoke execute on function public.admin_mark_restock_notified(bigint[], bigint) from public, anon, authenticated;
revoke execute on function public.create_settlements_for_order(bigint) from public, anon, authenticated;
revoke execute on function public.expire_unpaid_orders() from public, anon, authenticated;
revoke execute on function public.expire_old_coupons() from public, anon, authenticated;
revoke execute on function public.sweep_missing_ai_summaries(integer) from public, anon, authenticated;
revoke execute on function public.request_ai_summary_generation(bigint) from public, anon, authenticated;
revoke execute on function public.generate_order_number() from public, anon, authenticated;
revoke execute on function public.generate_pickup_request_number() from public, anon, authenticated;
revoke execute on function public.refresh_storefront_product_status(bigint) from public, anon, authenticated;
revoke execute on function public.lookup_guest_order(text, text, text) from public, anon, authenticated;

-- 서버리스 크론 호출 경로 보장 (이미 부여돼 있어도 멱등)
grant execute on function public.admin_mark_restock_notified(bigint[], bigint) to service_role;
grant execute on function public.expire_unpaid_orders() to service_role;
grant execute on function public.expire_old_coupons() to service_role;
