-- 묶음 10-3: books 가격/등급/상태 변경 audit log
--
-- 분쟁 시 어떤 운영자가 언제 어떤 값으로 변경했는지 추적 가능.
-- 트리거가 BEFORE UPDATE 시 변경 감지 후 book_change_logs에 row insert.

create table if not exists public.book_change_logs (
  id bigint generated always as identity primary key,
  book_id bigint not null references public.books(id) on delete cascade,
  changed_by uuid null references auth.users(id) on delete set null,
  field text not null,                  -- 'price' | 'condition_grade' | 'status' | 'is_public'
  old_value text null,
  new_value text null,
  changed_at timestamptz not null default now()
);

create index if not exists idx_book_change_logs_book_id
  on public.book_change_logs (book_id, changed_at desc);

alter table public.book_change_logs enable row level security;

drop policy if exists book_change_logs_admin_all on public.book_change_logs;
create policy book_change_logs_admin_all
  on public.book_change_logs
  for all
  to authenticated
  using (public.is_admin_user());

-- 트리거 함수: BEFORE UPDATE 시 변경 컬럼별로 row 기록
create or replace function public.books_log_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- price 변경
  if new.price is distinct from old.price then
    insert into public.book_change_logs (book_id, changed_by, field, old_value, new_value)
    values (new.id, auth.uid(), 'price', old.price::text, new.price::text);
  end if;

  -- condition_grade 변경
  if new.condition_grade is distinct from old.condition_grade then
    insert into public.book_change_logs (book_id, changed_by, field, old_value, new_value)
    values (new.id, auth.uid(), 'condition_grade', old.condition_grade, new.condition_grade);
  end if;

  -- status 변경
  if new.status is distinct from old.status then
    insert into public.book_change_logs (book_id, changed_by, field, old_value, new_value)
    values (new.id, auth.uid(), 'status', old.status, new.status);
  end if;

  -- is_public 변경
  if new.is_public is distinct from old.is_public then
    insert into public.book_change_logs (book_id, changed_by, field, old_value, new_value)
    values (new.id, auth.uid(), 'is_public', old.is_public::text, new.is_public::text);
  end if;

  return new;
end;
$$;

drop trigger if exists books_log_changes_trigger on public.books;
create trigger books_log_changes_trigger
before update on public.books
for each row
execute function public.books_log_changes();
