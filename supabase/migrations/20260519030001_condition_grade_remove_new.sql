-- 2026-05-19 정책 재정비: S(=새 책)와 A+ 두 등급으로 이원화. NEW 등급 폐지.
-- (NEW 추가 migration 20260519020001은 동일 일자에 적용되었지만, 사업 방향
--  재논의 결과 S가 곧 "새 책"을 의미하므로 별도 NEW 값이 불필요.)
--
-- 비파괴: NEW 값이 들어간 row가 있으면 S로 자동 마이그레이션 (사용자 의도와 동일).
-- 실제 운영 시점에는 NEW 옵션이 노출된 시간이 매우 짧아 0건일 가능성 높음.

-- 1) NEW 값으로 들어간 row가 있으면 S로 통합 (NEW = S = "새 책")
update public.books
set condition_grade = 'S'
where condition_grade = 'NEW';

-- 2) CHECK constraint를 원래대로 ('S', 'A_PLUS', 'A')
alter table public.books
  drop constraint if exists books_condition_grade_check;

alter table public.books
  add constraint books_condition_grade_check
  check (condition_grade is null or condition_grade in ('S', 'A_PLUS', 'A'));

-- 3) 정렬 함수를 NEW 분기 없이 원래대로
create or replace function public.storefront_condition_grade_rank(p_condition_grade text)
returns integer
language sql
immutable
set search_path = public
as $$
  select case coalesce(upper(btrim(coalesce(p_condition_grade, ''))), '')
    when 'S' then 1
    when 'A_PLUS' then 2
    when 'A' then 3
    else 99
  end;
$$;

comment on function public.storefront_condition_grade_rank(text) is
  '상품 정렬용 등급 rank. 낮을수록 우선 노출. S=1, A+=2, A=3.';
