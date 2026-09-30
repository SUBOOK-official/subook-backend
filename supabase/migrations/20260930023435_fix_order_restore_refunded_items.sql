-- 취소 주문 복원도 이전 주문에서 부분환불된 책은 활성 예약으로 보지 않는다.
-- 결제 이력·실제 타 주문 예약·판매/폐기 상태·쿠폰·권한 검사는 그대로 유지한다.
-- 데이터/RLS 변경 없음. 롤백: 추가한 oi2.refunded_at 조건만 제거한다.
DO $migration$
DECLARE
  definition text;
  old_predicate constant text := '                and o2.status not in (''cancelled'', ''refunded'')';
  new_predicate constant text := E'                and oi2.refunded_at is null\n                and o2.status not in (''cancelled'', ''refunded'')';
BEGIN
  definition := pg_get_functiondef('public.admin_restore_cancelled_order(bigint,boolean)'::regprocedure);
  IF (length(definition) - length(replace(definition, old_predicate, ''))) / length(old_predicate) <> 1
     OR position('oi2.refunded_at' in definition) > 0 THEN
    RAISE EXCEPTION 'Expected exactly one unpatched restore reservation predicate; inspect admin_restore_cancelled_order';
  END IF;
  EXECUTE replace(definition, old_predicate, new_predicate);
END;
$migration$;
