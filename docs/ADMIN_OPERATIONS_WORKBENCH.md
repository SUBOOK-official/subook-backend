# 어드민 운영 작업함 DB — 2026-10-06

적용 migration:

- `20261006064146_admin_operations_workbench.sql`
- `20261006072852_admin_coupon_operation_tags.sql`

관리자 업무를 위한 `admin_cs_cases`, `admin_work_jobs`, `admin_operation_events`, `admin_fulfillment_checks`, `admin_coupon_tags`를 추가한다. 모두 RLS를 사용한다. 익명/일반 회원은 운영 데이터를 읽거나 쓸 수 없다. 작업 결과는 작성 관리자만 갱신하며, 출고 체크는 전용 RPC에서 주문 상태·품목 소속·환불 상태와 피킹 완료를 검사한다.

목록 RPC는 기존 `list_admin_orders`, `list_admin_pickup_requests`를 대체하지 않고 별도 이름으로 추가했다. 주문 작업 보기/회원 ID/주문 ID와 수거 대상 ID를 페이지 제한 전에 적용한다. 날짜 경계는 KST다. 정산 예외·재고·업무 큐는 조회 전용이고 금액이나 금융 처리 정책을 수정하지 않는다.

변경 기록 트리거는 문의·작업·쿠폰·공지·FAQ·주문·수거 요청·검수 건에 적용된다. 값의 사본 없이 변경 필드명만 기록한다. 과거 상품/교재 이력은 조회 RPC에서 합친다. 기존 데이터의 수정/삭제·기존 RLS 완화·환경 변수 변경은 없다.

`node --test tests/admin-operations-workbench.test.js`로 두 실제 SQL migration을 격리된 PGlite DB에 적용해 8개 권한/업무 회귀 검사를 수행한다. 운영 적용은 검토된 두 파일만 포함한 격리 migration 디렉터리에서 dry-run 후 수행했으며, remote migration list에 두 버전이 일치함을 확인했다. 작업 시작 전에 존재하던 미추적 결제 migration은 포함하지 않았다.

복구는 이전 프런트 배포로 복귀하고 추가 테이블·기록은 보존하는 방식이다. 기록 트리거가 원인인 쓰기 장애가 확인되면 해당 트리거만 비활성화하는 별도 검토 migration을 작성한다. 운영 테이블 삭제나 기존 금융 함수 재정의를 복구에 묶지 않는다.
