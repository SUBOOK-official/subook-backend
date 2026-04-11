-- Remove sold_out status from books and keep only on_sale / settled.

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

