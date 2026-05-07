-- books의 메타데이터(subject/brand/book_type)는 대부분 비어있고 title만 있음.
-- 식스샵 product와 title로 직접 매칭하여 product_id 채우는 1회성 보정.
-- 추가 보너스: 매칭 후 product에서 subject/brand/book_type 등 메타데이터를
-- books에 reverse-copy해서 향후 검색/필터에도 활용 가능하게 한다.

create or replace function public.admin_link_books_by_title_to_products()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_step1 integer;
  v_step2 integer;
  v_meta_filled integer;
  v_total integer;
  v_unlinked integer;
begin
  if not (public.is_admin_user() or auth.role() = 'service_role') then
    raise exception 'Admin or service_role required';
  end if;

  -- Step 1: title + option 정확 매칭 (가장 안전)
  update public.books b
  set product_id = p.id
  from public.products p
  where b.product_id is null
    and lower(btrim(b.title)) = lower(btrim(p.title))
    and lower(btrim(coalesce(b.option, ''))) = lower(btrim(coalesce(p.option, '')));
  get diagnostics v_step1 = row_count;

  -- Step 2: 옵션 무시하고 title만으로 매칭. 같은 title의 product가 여러 개면
  --         id 가장 작은 것 (먼저 등록된 것)을 사용
  with candidates as (
    select distinct on (lower(btrim(p.title)))
      p.id, lower(btrim(p.title)) as title_lower
    from public.products p
    order by lower(btrim(p.title)), p.id
  )
  update public.books b
  set product_id = c.id
  from candidates c
  where b.product_id is null
    and lower(btrim(b.title)) = c.title_lower;
  get diagnostics v_step2 = row_count;

  -- Step 3: product_id가 채워진 books에 product의 메타데이터 reverse-copy
  --         (subject/brand/book_type이 비어있는 경우만)
  update public.books b
  set
    subject = coalesce(b.subject, p.subject),
    brand = coalesce(b.brand, p.brand),
    book_type = coalesce(b.book_type, p.book_type),
    published_year = coalesce(b.published_year, p.published_year),
    instructor_name = coalesce(b.instructor_name, p.instructor_name)
  from public.products p
  where b.product_id = p.id
    and (
      b.subject is null or b.brand is null or b.book_type is null
      or b.published_year is null or b.instructor_name is null
    );
  get diagnostics v_meta_filled = row_count;

  select count(*) into v_total from public.books;
  select count(*) into v_unlinked from public.books where product_id is null;

  return jsonb_build_object(
    'step1_title_option_match', v_step1,
    'step2_title_only_match', v_step2,
    'step3_meta_reverse_copied', v_meta_filled,
    'books_total', v_total,
    'books_still_unlinked', v_unlinked
  );
end;
$$;
