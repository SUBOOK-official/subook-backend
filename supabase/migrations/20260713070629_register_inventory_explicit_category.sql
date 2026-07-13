-- 통합 상품 등록: 신규 교재의 카테고리(과목/브랜드/유형) 명시 입력 지원
--
-- 배경(2026-07-13 피드백): 수거 → 교재 등록(/admin/register) 위저드에서 카테고리를
--   설정할 방법이 없었다. 메타는 _register_infer_product_meta가 상품명에서 추정하는데,
--   제목에 과목 키워드가 없으면 '기타'로 빠져 스토어 카테고리(과목) 분류가 틀어진다.
--
-- 변경: new_products 항목에 subject / brand / book_type 키가 오면 제목 파싱보다
--   우선 적용한다(빈 값이면 기존 파싱 폴백 — 하위호환, 구버전 프론트 payload 그대로 동작).
--   group_key와 products insert 양쪽 모두 동일 값으로 반영.
--
-- 본문은 20260629120000_product_register_flow.sql의 admin_register_customer_inventory
-- 정의에 override 3종만 추가 (CREATE OR REPLACE — 시그니처 동일, 비파괴).
--
-- p_payload = {
--   "new_products": [
--     { "title","original_price","discount_type","discount_value","option"(콤마분리),
--       "subject"?,"brand"?,"book_type"?,   -- ⬅ 신규(선택): 명시 카테고리
--       "cover_image_url","inspection_image_urls":[...], "is_public" }
--   ],
--   "existing_additions": [ ...변경 없음... ]
-- }

begin;

create or replace function public.admin_register_customer_inventory(
  p_shipment_id bigint,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_opt jsonb;
  v_meta record;
  v_prod record;
  v_group_key text;
  v_product_id bigint;
  v_existing_id bigint;
  v_title text;
  v_original integer;
  v_dtype text;
  v_dvalue integer;
  v_price integer;
  v_cover text;
  v_details text[];
  v_is_public boolean;
  v_qty integer;
  v_optname text;
  v_i integer;
  v_rep_original integer;
  v_options text[];
  v_subject text;
  v_brand text;
  v_btype text;
  v_created_products integer := 0;
  v_created_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from public.shipments where id = p_shipment_id) then
    raise exception '고객(수거) 정보를 찾을 수 없습니다.';
  end if;

  -- ── 신규 교재 ──────────────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'new_products', '[]'::jsonb))
  loop
    v_title := nullif(btrim(v_item->>'title'), '');
    if v_title is null then
      continue;
    end if;

    v_original := nullif(btrim(coalesce(v_item->>'original_price', '')), '')::integer;
    v_dtype := coalesce(nullif(v_item->>'discount_type', ''), 'none');
    v_dvalue := nullif(btrim(coalesce(v_item->>'discount_value', '')), '')::integer;
    v_price := public._register_compute_price(v_original, v_dtype, v_dvalue);
    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;
    v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;

    select * into v_meta from public._register_infer_product_meta(v_title);
    -- 명시 카테고리가 오면 제목 파싱보다 우선 (빈 값이면 파싱 폴백 — 2026-07-13)
    v_subject := coalesce(nullif(btrim(coalesce(v_item->>'subject', '')), ''), v_meta.subject);
    v_brand   := coalesce(nullif(btrim(coalesce(v_item->>'brand', '')), ''), v_meta.brand);
    v_btype   := coalesce(nullif(btrim(coalesce(v_item->>'book_type', '')), ''), v_meta.book_type);
    v_group_key := public.storefront_product_group_key(
      v_title, null, v_subject, v_brand, v_btype, v_meta.year, v_meta.instructor
    );

    select id into v_existing_id from public.products where group_key = v_group_key;
    if v_existing_id is null then
      insert into public.products (
        group_key, title, option, subject, brand, book_type,
        published_year, instructor_name, cover_image_url, status
      ) values (
        v_group_key, v_title, null, v_subject, v_brand, v_btype,
        v_meta.year, v_meta.instructor, v_cover, 'selling'
      ) returning id into v_product_id;
      v_created_products := v_created_products + 1;
    else
      v_product_id := v_existing_id;
      if v_cover is not null then
        update public.products
        set cover_image_url = coalesce(cover_image_url, v_cover), updated_at = now()
        where id = v_product_id;
      end if;
    end if;

    v_options := array(
      select btrim(x) from regexp_split_to_table(coalesce(v_item->>'option', ''), ',') x
      where btrim(x) <> ''
    );
    if array_length(v_options, 1) is null then
      v_options := array[null]::text[];
    end if;

    foreach v_optname in array v_options
    loop
      insert into public.books (
        shipment_id, title, option, product_id, original_price, price, condition_grade,
        cover_image_url, inspection_image_urls, status, is_public,
        discount_type, discount_value, inspected_at
      ) values (
        p_shipment_id, v_title, nullif(v_optname, ''), v_product_id, v_original, v_price, 'S',
        v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
        v_dtype, v_dvalue, now()
      );
      v_created_books := v_created_books + 1;
    end loop;
  end loop;

  -- ── 기존 교재 재고 추가 ────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'existing_additions', '[]'::jsonb))
  loop
    v_product_id := nullif(btrim(coalesce(v_item->>'product_id', '')), '')::bigint;
    if v_product_id is null then
      continue;
    end if;

    select * into v_prod from public.products where id = v_product_id;
    if not found then
      continue;
    end if;

    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;

    select max(original_price) into v_rep_original
    from public.books where product_id = v_product_id and status = 'on_sale';

    if v_cover is not null and v_prod.cover_image_url is null then
      update public.products set cover_image_url = v_cover, updated_at = now() where id = v_product_id;
    end if;

    for v_opt in
      select value from jsonb_array_elements(coalesce(v_item->'options', '[]'::jsonb))
    loop
      v_qty := coalesce(nullif(btrim(coalesce(v_opt->>'quantity', '')), '')::integer, 0);
      if v_qty < 1 then
        continue;
      end if;
      v_optname := nullif(btrim(coalesce(v_opt->>'option', '')), '');
      v_price := nullif(btrim(coalesce(v_opt->>'price', '')), '')::integer;
      v_original := coalesce(nullif(btrim(coalesce(v_opt->>'original_price', '')), '')::integer, v_rep_original);
      v_dtype := coalesce(nullif(v_opt->>'discount_type', ''), 'none');
      v_dvalue := nullif(btrim(coalesce(v_opt->>'discount_value', '')), '')::integer;
      v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;

      for v_i in 1..v_qty
      loop
        insert into public.books (
          shipment_id, title, option, product_id, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at
        ) values (
          p_shipment_id, v_prod.title, v_optname, v_product_id, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now()
        );
        v_created_books := v_created_books + 1;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object(
    'success', true,
    'created_products', v_created_products,
    'created_books', v_created_books
  );
end;
$$;

commit;
