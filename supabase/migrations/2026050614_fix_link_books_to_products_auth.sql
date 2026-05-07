-- 2026050613의 admin_link_books_to_products를 service_role도 호출 가능하도록 보정.
-- service_role JWT는 auth.uid()가 null이라 is_admin_user() false → 우회 분기 추가.

create or replace function public.admin_link_books_to_products()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_linked_count integer;
  v_total integer;
  v_unlinked integer;
  v_unlinked_with_meta integer;
begin
  if not (public.is_admin_user() or auth.role() = 'service_role') then
    raise exception 'Admin or service_role required';
  end if;

  update public.books b
  set product_id = p.id
  from public.products p
  where b.product_id is null
    and nullif(btrim(coalesce(b.title, '')), '') is not null
    and b.subject is not null
    and b.brand is not null
    and b.book_type is not null
    and p.group_key = public.storefront_product_group_key(
      b.title, b.option, b.subject, b.brand, b.book_type, b.published_year, b.instructor_name
    );

  get diagnostics v_linked_count = row_count;

  select count(*) into v_total from public.books;
  select count(*) into v_unlinked from public.books where product_id is null;
  select count(*) into v_unlinked_with_meta
    from public.books
    where product_id is null
      and subject is not null
      and brand is not null
      and book_type is not null;

  return jsonb_build_object(
    'linked', v_linked_count,
    'books_total', v_total,
    'books_still_unlinked', v_unlinked,
    'books_unlinked_with_full_meta', v_unlinked_with_meta
  );
end;
$$;
