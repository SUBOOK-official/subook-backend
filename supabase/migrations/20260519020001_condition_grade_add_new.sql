-- 2026-05-19 사업 방향성 전환: 신규 입고는 모두 "NEW(새 책)" 등급으로 매입.
-- 기존 S/A+/A 데이터는 그대로 유지 (재고 소진까지 같은 그리드에서 함께 노출).
--
-- 변경사항
--   1) books.condition_grade CHECK constraint에 'NEW' 허용 값 추가
--   2) storefront_condition_grade_rank에 'NEW' 분기 추가 (가장 높은 우선순위)
--
-- 비파괴: 기존 데이터 변경 없음, 새 값 추가만.

-- 1) CHECK constraint 갱신
alter table public.books
  drop constraint if exists books_condition_grade_check;

alter table public.books
  add constraint books_condition_grade_check
  check (condition_grade is null or condition_grade in ('NEW', 'S', 'A_PLUS', 'A'));

-- 2) 정렬 함수: NEW를 가장 앞에 (rank 0)
create or replace function public.storefront_condition_grade_rank(p_condition_grade text)
returns integer
language sql
immutable
set search_path = public
as $$
  select case coalesce(upper(btrim(coalesce(p_condition_grade, ''))), '')
    when 'NEW' then 0
    when 'S' then 1
    when 'A_PLUS' then 2
    when 'A' then 3
    else 99
  end;
$$;

comment on function public.storefront_condition_grade_rank(text) is
  '상품 정렬용 등급 rank. 낮을수록 우선 노출. 2026-05-19 NEW(=0) 추가.';
