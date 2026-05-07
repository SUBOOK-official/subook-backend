-- books_enforce_public_storefront_rules_trigger가 product_id를 강제로 reset해서
-- 일괄 매칭이 적용되지 않는 문제 해결.
-- 트랜잭션 내에서 트리거를 일시 비활성화하고 books ↔ products를 매칭한다.
-- 1회성 보정 작업.

create or replace function public.admin_force_link_books_by_title()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_step1 integer;
  v_step2 integer;
  v_meta integer;
  v_unlinked integer;
begin
  if not (public.is_admin_user() or auth.role() = 'service_role') then
    raise exception 'Admin or service_role required';
  end if;

  -- 명시적으로 매칭 트리거 비활성화 (정합성 검증 트리거)
  alter table public.books disable trigger books_enforce_public_storefront_rules_trigger;
  -- 그 외 product status refresh 트리거도 임시 비활성화 (대량 update 시 성능)
  alter table public.books disable trigger books_refresh_storefront_product_status_trigger;

  -- Step 1: title + option 정확 매칭
  update public.books b
  set product_id = p.id
  from public.products p
  where b.product_id is null
    and lower(btrim(b.title)) = lower(btrim(p.title))
    and lower(btrim(coalesce(b.option, ''))) = lower(btrim(coalesce(p.option, '')));
  get diagnostics v_step1 = row_count;

  -- Step 2: title만으로 매칭 (DISTINCT ON으로 동일 title의 product 중 id 가장 작은 것)
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

  -- Step 3: product의 subject/brand/book_type 등 메타데이터를 books로 reverse-copy
  --         (books의 메타데이터가 비어있을 때만)
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
  get diagnostics v_meta = row_count;

  -- 트리거 재활성화
  alter table public.books enable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books enable trigger books_refresh_storefront_product_status_trigger;

  select count(*) into v_unlinked from public.books where product_id is null;

  return jsonb_build_object(
    'step1_title_option', v_step1,
    'step2_title_only', v_step2,
    'step3_meta_copied', v_meta,
    'still_unlinked', v_unlinked
  );
end;
$$;
