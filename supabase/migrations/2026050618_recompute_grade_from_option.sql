-- books.condition_grade를 books.option 텍스트에서 추출해 재계산.
-- 사용자 정책:
--   - option에 'A+' 표기가 있으면 → 'A_PLUS'
--   - option에 'A' 단독 표기가 있으면 → 'A'
--   - 그 외 (표기 없음) → 'S' (default 새책)
--
-- 이전 마이그레이션(2026050617)이 모든 NULL을 'S'로 일괄 update했지만
-- 'A+' / 'A' 표기 케이스도 'S'가 되어버려 보정 필요.

do $$
declare
  v_a_plus integer;
  v_a integer;
  v_s integer;
begin
  alter table public.books disable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books disable trigger books_refresh_storefront_product_status_trigger;

  -- Step 1: option에 'A+' 표기 → A_PLUS
  update public.books
  set condition_grade = 'A_PLUS'
  where option ~ 'A\+';
  get diagnostics v_a_plus = row_count;

  -- Step 2: A_PLUS 아니면서 option에 'A' 단독 표기 → A
  --         (\s|-) 공백/대시 다음 A 다음에 + 또는 단어문자가 아닌 것
  update public.books
  set condition_grade = 'A'
  where condition_grade <> 'A_PLUS'
    and option ~ '(\s|-)\s*A([^A-Za-z+]|$)';
  get diagnostics v_a = row_count;

  -- Step 3: 그 외는 S (이미 그렇지만 명시적으로)
  update public.books
  set condition_grade = 'S'
  where condition_grade not in ('A_PLUS', 'A');
  get diagnostics v_s = row_count;

  raise notice '재계산 결과 — A_PLUS: %, A: %, S: %', v_a_plus, v_a, v_s;

  alter table public.books enable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books enable trigger books_refresh_storefront_product_status_trigger;
end $$;
