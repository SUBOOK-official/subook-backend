-- sold_out을 settled로 다시 통합 (사용자 요청).
-- 2026050804에서 잠깐 풀었던 sold_out을 settled로 흡수하고, CHECK 제약도 원복.

update public.books
set status = 'settled'
where status = 'sold_out';

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
  check (status in ('on_sale', 'settled'));
