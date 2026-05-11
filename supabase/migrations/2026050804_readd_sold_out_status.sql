-- 2026021102에서 제거됐던 'sold_out' status 재추가.
-- 의미상 'settled'(정산완료)와 다른 케이스:
--   - 엑셀(창고 실제 재고)에는 없는데 DB엔 on_sale로 남아있는 책
--   - = 분실/오등록 가능성, 정산 여부 불분명
--   - 그래서 'settled'보다는 'sold_out'(품절)이 의미적으로 맞음

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
  check (status in ('on_sale', 'settled', 'sold_out'));
