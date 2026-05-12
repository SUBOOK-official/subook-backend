-- 묶음 7: 검수 폐기 등급 추가
--
-- 운영진이 검수 시 "폐기"로 분류할 수 있는 등급 추가.
-- 폐기 책은 books.status='discarded'로 분리되어 storefront에 노출되지 않고
-- settlement도 생성되지 않는다. (정산 0원)

-- 1) books.condition_grade에 'DISCARD' 추가
alter table public.books drop constraint if exists books_condition_grade_check;
alter table public.books add constraint books_condition_grade_check
  check (condition_grade is null or condition_grade in ('S', 'A_PLUS', 'A', 'DISCARD'));

-- 2) books.status에 'discarded' 추가
do $$
declare
  status_constraint record;
begin
  for status_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.books'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format(
      'alter table public.books drop constraint if exists %I',
      status_constraint.conname
    );
  end loop;
end;
$$;

alter table public.books
  add constraint books_status_check
  check (status in ('on_sale', 'settled', 'discarded'));
