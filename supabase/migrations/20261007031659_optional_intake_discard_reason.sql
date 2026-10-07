-- 2026-10-07 운영 결정: 폐기 사유를 입력하지 않고 검수 등록한다.
-- 현행 함수의 해당 검증 한 줄만 제거한다. 권한·RLS·기존 데이터·폐기 상태 전이는 유지.
-- 롤백: 아래 old_guard를 v_grade='DISCARD' 분기의 v_public:=false 앞에 복원한다.
DO $migration$
DECLARE
  definition text;
  old_guard constant text := $guard$    if nullif(btrim(p_item->>'discard_reason'),'') is null then raise exception '판매불가 사유를 입력하세요.'; end if;
$guard$;
BEGIN
  definition := pg_get_functiondef('public.admin_register_intake_book(bigint,uuid,jsonb)'::regprocedure);
  IF (length(definition) - length(replace(definition, old_guard, ''))) / length(old_guard) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one discard-reason guard; inspect current admin_register_intake_book';
  END IF;
  EXECUTE replace(definition, old_guard, '');
END;
$migration$;
