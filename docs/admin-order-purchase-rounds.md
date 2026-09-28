# 주문·배송 재구매 딱지

2026-09-28: 주문 목록과 펼친 상세의 고객명 옆에 `재구매 2회차`부터 표시한다. 첫 주문은 딱지가 없다.

- 주문별로 **그 주문 이전 결제 이력 + 이번 주문 1회**를 센다. 이후 주문 때문에 과거 주문의 차수가 증가하지 않는다.
- 회원은 `user_id`, 비회원은 숫자만 남긴 수령인 전화번호로 식별한다. 회원·비회원 이력을 서로 합치지 않으며 빈 전화번호끼리 합치지 않는다.
- 기존 성과 대시보드와 동일하게 `payment_status`가 `paid` 또는 `refunded`이고 결제 시각이 있는 이력만 센다. 결제 후 환불한 구매 경험도 포함한다.
- 결제 시각은 `paid_at`, 없으면 `pg_approved_at`이다. 동시각은 주문 ID로 순서를 고정한다.
- 현재 주문이 미결제면 생성 시각을 기준으로 이전 결제를 조회한다. 입금대기·취소 주문은 다른 주문의 구매 횟수를 늘리지 않는다.
- 검색·기간·상태·페이지 필터와 무관하게 전체 결제 이력을 참조한다. 구사이트 이력은 합치지 않는다.

`admin_order_purchase_rounds(uuid[])`는 관리자만 최대 100개 주문의 차수를 조회하는 읽기 전용 RPC다. 테이블·RLS·결제·배송 처리 변경은 없다. 프론트는 조회 실패 시 딱지를 생략하고 오류 토스트를 표시한다.

검증: `node --test tests/order-purchase-rounds.test.js` (backend에서 실행).

공식 근거: [Supabase 함수 및 실행 권한](https://supabase.com/docs/guides/database/functions), [JavaScript RPC](https://supabase.com/docs/reference/javascript/rpc).
