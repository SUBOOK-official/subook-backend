-- 1) admin_get_product_inventory에 option 컬럼 추가 (모달에 셀러별 어떤 옵션의 책인지 표시)
-- 2) books.condition_grade NULL → 'S'로 일괄 보정
--    사용자 정책: 옵션에 'A+' 등 등급 표기 없으면 모두 S급으로 간주
--    (트리거 우회 후 update)

create or replace function public.admin_get_product_inventory(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product jsonb;
  v_books jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select to_jsonb(p) into v_product from public.products p where p.id = p_product_id;
  if v_product is null then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'shipment_id', b.shipment_id,
    'seller_name', s.seller_name,
    'seller_phone', s.seller_phone,
    'option', b.option,
    'condition_grade', coalesce(b.condition_grade, 'S'),
    'price', b.price,
    'status', b.status,
    'is_public', b.is_public,
    'cover_image_url', b.cover_image_url,
    'created_at', b.created_at
  ) order by s.seller_name nulls last, b.option nulls last, b.id), '[]'::jsonb)
  into v_books
  from public.books b
  left join public.shipments s on s.id = b.shipment_id
  where b.product_id = p_product_id;

  return jsonb_build_object('product', v_product, 'books', v_books);
end;
$$;

-- condition_grade default 'S' 보정
do $$
declare
  v_count integer;
begin
  alter table public.books disable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books disable trigger books_refresh_storefront_product_status_trigger;

  update public.books
  set condition_grade = 'S'
  where condition_grade is null;

  get diagnostics v_count = row_count;
  raise notice 'condition_grade S로 보정된 books: %', v_count;

  alter table public.books enable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books enable trigger books_refresh_storefront_product_status_trigger;
end $$;
