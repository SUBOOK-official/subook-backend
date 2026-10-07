# 쿠폰 브랜드·과목 제한

2026-10-07: `scope_brand`, `scope_subject`는 각각 NULL이면 제한 없음이며 둘 다 지정하면 AND 조건이다. 과목은 상품 등록의 대분류(국어·수학·영어·과학·사회·한국사·기타)다.

대상 교재 합계에 최소 주문금액과 정액·정률 할인 상한을 적용한다. 무료배송 쿠폰도 대상 교재 조건을 검사한다. 기존 과목 미지정 쿠폰은 그대로 모든 과목에 사용할 수 있다.

`get_applicable_coupons`는 실제 book_id로 계산한 `eligible_subtotal`을 반환한다. 주문서의 미리보기·추천 할인액·결제금액 계산은 이 값을 사용한다. `create_order_core`는 카드 세션 생성·확정과 무통장 주문에서 같은 제한을 재검증한다. 쿠폰함 RPC도 두 조건을 반환한다.

이번 migration은 기존 함수 정의의 쿠폰 관련 구문만 교체하며 RLS·ACL·포인트·게스트·부분환불 재고 가드를 유지한다. 예전 포인트 migration에서 빠졌던 브랜드 제한도 복원한다. 기존 함수가 예상과 다르면 적용을 중단한다.

검증: `node --test backend/tests/coupon-subject-scope.test.js` (루트 기준). 혼합 주문·교집합·최소금액·정액/정률/무료배송·제한 수정/해제·권한·만료·사용한도·포인트·카드 세션/확정 및 무통장 주문을 검사한다.

롤백은 새 과목 제한 쿠폰을 비활성화한 뒤 migration의 함수 교체를 역적용한다. 설정값 보존을 위해 컬럼은 제거하지 않는다. 기존 브랜드 제한이 빠져 있던 주문 계산으로 되돌리지 않도록 주의한다.

공식 확인 근거: [Supabase DB push](https://supabase.com/docs/reference/cli/supabase-db-push), [Management SQL query](https://supabase.com/docs/reference/api/v1-run-a-query).
