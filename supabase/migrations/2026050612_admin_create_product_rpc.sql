-- 어드민이 직접 새 상품을 등록하는 RPC.
-- 식스샵 마이그레이션 후 누락된 책 또는 신상품을 어드민에서 수동으로 추가하는 흐름.
-- group_key는 storefront_product_group_key()로 자동 계산하고 중복 시 에러로 알려준다.

create or replace function public.admin_create_product(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_key text;
  v_id bigint;
  v_existing_id bigint;
  v_title text;
  v_subject text;
  v_brand text;
  v_book_type text;
  v_published_year integer;
  v_instructor_name text;
  v_option text;
  v_cover_image_url text;
  v_status text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_title := nullif(btrim(p_payload->>'title'), '');
  if v_title is null then
    raise exception '상품 이름은 필수입니다.';
  end if;

  v_subject := nullif(btrim(p_payload->>'subject'), '');
  v_brand := nullif(btrim(p_payload->>'brand'), '');
  v_book_type := nullif(btrim(p_payload->>'book_type'), '');

  if v_subject is null then raise exception '과목을 선택해 주세요.'; end if;
  if v_brand is null then raise exception '브랜드를 선택해 주세요.'; end if;
  if v_book_type is null then raise exception '책 타입을 선택해 주세요.'; end if;

  v_published_year := nullif(p_payload->>'published_year', '')::integer;
  v_instructor_name := nullif(btrim(p_payload->>'instructor_name'), '');
  v_option := nullif(btrim(p_payload->>'option'), '');
  v_cover_image_url := nullif(btrim(p_payload->>'cover_image_url'), '');
  v_status := coalesce(p_payload->>'status', 'selling');

  if v_status not in ('selling', 'sold_out', 'hidden') then
    raise exception '올바르지 않은 상태입니다.';
  end if;

  v_group_key := public.storefront_product_group_key(
    v_title, v_option, v_subject, v_brand, v_book_type, v_published_year, v_instructor_name
  );

  -- 중복 검사: 같은 group_key가 이미 있으면 거부 (수정은 별도 RPC로)
  select id into v_existing_id from public.products where group_key = v_group_key;
  if v_existing_id is not null then
    raise exception '이미 같은 메타데이터의 상품이 존재합니다. (기존 id: %)', v_existing_id;
  end if;

  insert into public.products (
    group_key, title, option, subject, brand, book_type,
    published_year, instructor_name, cover_image_url, status
  )
  values (
    v_group_key, v_title, v_option, v_subject, v_brand, v_book_type,
    v_published_year, v_instructor_name, v_cover_image_url, v_status
  )
  returning id into v_id;

  return jsonb_build_object('success', true, 'product_id', v_id);
end;
$$;

grant execute on function public.admin_create_product(jsonb) to authenticated;
