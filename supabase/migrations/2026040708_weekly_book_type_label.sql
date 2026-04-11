update public.books
set book_type = '주간지'
where book_type = '추금지';

alter table public.books
  drop constraint if exists books_book_type_check;

alter table public.books
  add constraint books_book_type_check
  check (book_type is null or book_type in ('기출', '모의고사', 'N제', 'EBS', '주간지', '내신'));
