drop policy if exists books_delete_public on public.books;
drop policy if exists books_delete_admin on public.books;

create policy books_delete_admin
  on public.books
  for delete
  to authenticated
  using (public.is_admin_user());
