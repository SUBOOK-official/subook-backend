-- 부분환불 후 재판매한 책은 이전 주문의 결제 확정과 충돌하지 않는다.
-- 무통장(단건/일괄)·PG 모두 미환불 품목만 중복 판매로 검사한다.
-- 현재 정의의 조건만 교체해 관리자 검사·금액·멱등성·권한·상태 전이를 보존한다.
-- 데이터/RLS 변경 없음. 두 함수 교체는 하나의 DO 문에서 원자적으로 적용한다.
-- 롤백: 두 함수의 충돌 검사에서 추가한 oi2.refunded_at 조건만 제거한다.
-- 배포 절차: https://supabase.com/docs/guides/deployment/database-migrations
DO $migration$
DECLARE
  function_signature regprocedure;
  definition text;
  old_predicate constant text := '    and o2.status not in (''pending'', ''cancelled'', ''refunded'');';
  new_predicate constant text := E'    and oi2.refunded_at is null\n    and o2.status not in (''pending'', ''cancelled'', ''refunded'');';
BEGIN
  FOREACH function_signature IN ARRAY ARRAY[
    'public.admin_confirm_payment(bigint,integer)'::regprocedure,
    'public.confirm_pg_payment(text,text,integer,text,jsonb)'::regprocedure
  ] LOOP
    definition := pg_get_functiondef(function_signature);
    IF (length(definition) - length(replace(definition, old_predicate, ''))) / length(old_predicate) <> 1
       OR position('oi2.refunded_at' in definition) > 0 THEN
      RAISE EXCEPTION 'Expected exactly one unpatched payment conflict predicate in %; inspect current definition', function_signature;
    END IF;
    EXECUTE replace(definition, old_predicate, new_predicate);
  END LOOP;
END;
$migration$;
