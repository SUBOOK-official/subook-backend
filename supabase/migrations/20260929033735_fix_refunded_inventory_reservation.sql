-- 부분환불 후 재입고된 권을 과거 주문의 활성 예약으로 오인하지 않는다.
-- 현재 함수 본문에서 예약 조건 하나만 교체하여 이후 결제·포인트·게스트 변경을 보존한다.
-- 데이터/권한/상태 전이 변경 없음. 롤백: 아래 조건에서 oi.refunded_at is null만 제거.
DO $migration$
DECLARE
  definition text;
  old_predicate constant text := E'where oi.book_id = v_book.id\n      and o.status not in (''cancelled'', ''refunded'')';
  new_predicate constant text := E'where oi.book_id = v_book.id\n      and oi.refunded_at is null\n      and o.status not in (''cancelled'', ''refunded'')';
BEGIN
  SELECT pg_get_functiondef(oid) INTO STRICT definition
  FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='create_order_core';
  IF (length(definition)-length(replace(definition,old_predicate,'')))/length(old_predicate) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one active reservation predicate; inspect current create_order_core';
  END IF;
  EXECUTE replace(definition,old_predicate,new_predicate);
END;
$migration$;
