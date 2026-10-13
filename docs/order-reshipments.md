# 환불 없는 무상 재발송

2026-10-13: 오배송·누락 대응용으로 주문 상세의 **무상 재발송 → 재발송 송장 발급**을 추가했다.

- 결제된 배송중·배송완료·구매확정 주문의 미환불 품목을 선택한다. 실제 보낼 교재명(편/옵션)과 수량, 합의 사유를 입력하고 배송지를 확인한다.
- 원 주문의 송장·상태·금액·환불·정산 및 합배송은 그대로 보존한다. 재고 조정과 반품 수거는 기존 운영 절차로 별도 처리한다. 고객 알림은 자동 발송하지 않는다.
- 미종결 환불 신청 중에도 재발송할 수 있다. 기존 자동확정·정산 보류는 유지한다. 재발송 후 고객 확인이 끝나면 기존 환불 신청 종결 기능을 사용한다.
- CJ에는 별도 관리번호 `RS-<재발송 ID>`, 선택한 실제 교재명과 수량으로 1박스를 접수한다. 발급 이력에서 재출력·배송조회가 가능하다. 조회는 기존 CJ 스캔 조회를 사용하며 원 주문의 배송완료/자동확정 시각을 변경하지 않는다.

## 중복 발급 방지

`order_reshipments`는 RLS 활성화 및 service_role 전용이다. 관리자 JWT를 검사하는 `cj-delivery` API만 호출한다. 일반 회원/비회원은 테이블 및 RPC에 접근할 수 없다. 이력 응답에서 작업 소유권 토큰은 제외한다.

1. 주문 행 잠금과 활성 재발송 유일 인덱스로 동시 접수를 직렬화한다. 요청 UUID 재사용은 동일 발급으로 처리한다.
2. 새로운 재발송은 화면이 조회한 최신 이력 ID를 확인한다. 다른 화면에서 발급한 뒤 오래된 화면으로 다시 접수할 수 없다.
3. 채번 후 CJ 예약 전에 번호·라우팅을 `booking`으로 저장한다. CJ 통신 실패·중복 응답·접수 후 DB 저장 실패는 번호를 보존하고 자동 재예약·취소를 금지한다.
4. 채번 전 실패와 CJ의 명시적인 신규 접수 거부만 같은 요청으로 다시 시도할 수 있다. `claimed`가 10분 이상 남으면 기존 이력의 **같은 재발송 다시 시도**로 복구한다.
5. 발급 중 원 주문 주소·상태·환불 품목 변경을 차단한다. 실제 접수 성공이 확인된 `booking` 건만 운영자가 `admin_transition_order_reshipment(id, claim_token, 'registered')`로 확정할 수 있다. CJ에 접수가 없거나 취소되었음을 확인한 경우에만 `'rejected'`로 해제한다. 확인 없이 해제하지 않는다.

검증: backend `node --test tests/order-reshipments.test.js`, frontend `npm run test:admin`.
SQL은 격리 PGlite DB, API는 HTTP mock으로 검증한다. 실제 주문에 테스트 송장을 발급하지 않는다.

근거: [CJ 공식 표준 API V3.9.4](cj/CJLAPI-택배표준API-DeveloperGuide-V3.9.4.pdf) 15–19쪽(RegBook 고객사용번호·합포장 키·품목), [Supabase 함수 권한](https://supabase.com/docs/guides/database/functions), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).
