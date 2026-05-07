-- 기존 books의 메타데이터로 group_key 계산하여 같은 키의 product에 일괄 link.
-- 1회성 작업이지만 재실행 안전 (where product_id is null만 처리).
-- 검수 시점에 트리거가 정상 동작했어야 했지만, 메타데이터 보정/식스샵 import 이후
-- 누락된 books를 한 번에 묶어준다.

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
  -- service_role 또는 admin 사용자만 호출 가능. 1회성 데이터 보정 RPC.
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

grant execute on function public.admin_link_books_to_products() to authenticated;
