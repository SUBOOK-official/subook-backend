# 배송 후 회수 면제 환불

2026-10-05 사용자 요청. 이미 풀이된 모의고사 등 하자가 확인된 교재를 회수하지 않고 환불한다.

- 관리자 주문의 반품·환불에서 품목을 선택하고 **보냈지만 반품 없이 환불해요**를 선택한다.
- 하자·회수 면제 사유를 입력한다. 일부 환불은 최종 환불액과 계산 근거를 확인한다. 반품 배송비는 0원이다.
- 접수·금액 확인으로는 결제가 취소되지 않는다. 마지막 승인 화면에서 카드 환불 실행 또는 무통장 송금 완료 기록을 진행한다.
- 환불 품목은 폐기 상태로 기록하며 재판매·회수 대기에서 제외한다. 물류 수거·실물 도착·창고 폐기를 했다는 의미는 아니다.
- 접수 중 정산 생성 및 기존 정산 송금 보류. 환불 완료 후 선택 품목의 미지급 정산 취소, 이후 생성 제외. 나머지 정상 품목은 정산 가능하다.
- 이미 지급된 정산은 원 지급 내역을 삭제하지 않는다. PG 실행 전에 기존 손실 확인을 요구하고, 환불 후 회수 필요로 기록한다.

기존 금액 승인·환불 토큰·PG 잔액 대사·중복 방지·쿠폰/포인트 처리는 재사용한다. API 미러 변경은 없다. `return_waived`는 기존 관리자 RLS로 보호되며, DB 제약으로 실물 회수·재판매 플래그와 동시 설정할 수 없다.

검증: `node --test tests/return-refund.test.js`는 실제 migration/RPC를 격리 PostgreSQL(PGlite)에서 실행한다. 구매확정 후 일부 환불, 지급완료 정산, 멱등성, 금액/권한 검증, 재판매 제외, 정산 생성 보류 및 환불 품목 재생성 방지를 포함한다. 기존 환불 API·공유 금액·공개웹 테스트, lint 및 admin/public build도 실행한다.

적용 migration: `20261005134046_delivered_defect_no_return_refund.sql`. 기존 운영 행을 보정하는 SQL은 없다. 롤백은 UI 진입점을 제거한 뒤 진행 중인 환불을 기존 토큰으로 대사·완료하고, 이력은 보존한다.

공식 확인: [Supabase DB 함수 권한](https://supabase.com/docs/guides/database/functions), [Migration push/dry-run](https://supabase.com/docs/reference/cli/supabase-db-push), [읽기 전용 운영 조회](https://supabase.com/docs/reference/api/v1-run-a-query).
