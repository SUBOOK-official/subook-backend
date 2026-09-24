-- 홈 연도 필터: 2027 / 2026 / 2025 / 기타.
-- p_years의 0은 대표 연도 외 모든 연도(NULL 포함). 기존 정수 연도 요청은 그대로 동작한다.
-- 현재 함수의 연도 조건만 교체해 검색·품절 노출·정렬·권한을 보존한다.
-- 테이블/데이터/RLS/실행 권한 변경 없음.
-- 롤백: 아래 new_predicate를 old_predicate로 역치환. 먼저 프론트의 기타 옵션을 숨긴다.
DO $migration$
DECLARE
  function_definition text;
  old_predicate constant text := '(coalesce(cardinality(p_years), 0) = 0 or p.published_year = any(p_years))';
  new_predicate constant text := '(coalesce(cardinality(p_years), 0) = 0
        or p.published_year = any(p_years)
        or (0 = any(p_years) and (p.published_year is null or p.published_year not in (2027, 2026, 2025))))';
BEGIN
  function_definition := pg_get_functiondef(
    'public.list_public_store_products(text[],text[],text[],integer[],text[],text,text,integer,integer,text[],text[])'::regprocedure
  );
  IF position(old_predicate in function_definition) = 0
    OR (length(function_definition) - length(replace(function_definition, old_predicate, ''))) / length(old_predicate) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one storefront year predicate; inspect the current function before applying';
  END IF;
  EXECUTE replace(function_definition, old_predicate, new_predicate);
END;
$migration$;
