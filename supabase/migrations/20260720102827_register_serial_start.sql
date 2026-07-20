-- 상품 등록: 시작 일련번호(운영자 지정) 순차 배정 지원
--
-- 배경(2026-07-20): 실물 라벨 스티커 롤을 이어 붙이는 운영 방식에 맞춰, 등록 배치의
--   시작 일련번호를 운영자가 직접 정하면 등록 순서(신규 교재 표 → 기존 교재 추가)대로
--   start, start+1, start+2, ... 가 순차 배정된다. 미지정 시 기존 시퀀스 자동 채번 유지.
--
-- 변경 요약 (비파괴: CREATE OR REPLACE 1건):
--   * admin_register_customer_inventory (20260717193926 최신 정의 기반)
--     - p_payload.serial_start (선택, 정수) 추가 — 지정 시 그 번호부터 순차 배정
--     - 배정 예정 번호가 이미 사용 중이면 예외(전체 롤백) → 다른 시작 번호 안내
--     - 수동 배정 후 books_serial_number_seq를 뒤처지지 않게 동기화
--     - 시그니처 동일(p_shipment_id, p_payload) — 구버전 프론트 payload도 그대로 동작

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
  v_location text;
  v_serial integer;
  v_serial_start integer;
  v_created_serials integer[] := '{}'::integer[];
  v_created_products integer := 0;
  v_created_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from public.shipments where id = p_shipment_id) then
    raise exception '고객(수거) 정보를 찾을 수 없습니다.';
  end if;

  -- 시작 일련번호 (2026-07-20): 지정 시 등록 순서대로 start, start+1, ... 순차 배정
  v_serial_start := nullif(btrim(coalesce(p_payload->>'serial_start', '')), '')::integer;
  if v_serial_start is not null and v_serial_start < 1 then
    raise exception '시작 일련번호는 1 이상의 숫자여야 합니다.';
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
    -- 창고 위치 (2026-07-18: NFKC 정규화 — 전각/반각 통일)
    v_location := nullif(normalize(btrim(coalesce(v_item->>'location', '')), nfkc), '');

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
      if v_serial_start is not null then
        v_serial := v_serial_start + v_created_books;
        if exists (select 1 from public.books where serial_number = v_serial) then
          raise exception '일련번호 %가 이미 사용 중입니다. 다른 시작 번호를 입력해 주세요.', v_serial;
        end if;
      else
        v_serial := public._next_book_serial();
      end if;
      insert into public.books (
        shipment_id, title, option, product_id, original_price, price, condition_grade,
        cover_image_url, inspection_image_urls, status, is_public,
        discount_type, discount_value, inspected_at, serial_number, location
      ) values (
        p_shipment_id, v_title, nullif(v_optname, ''), v_product_id, v_original, v_price, 'S',
        v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
        v_dtype, v_dvalue, now(), v_serial, v_location
      );
      v_created_books := v_created_books + 1;
      v_created_serials := v_created_serials || v_serial;
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
    -- 창고 위치 (2026-07-18)
    v_location := nullif(normalize(btrim(coalesce(v_item->>'location', '')), nfkc), '');

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
        if v_serial_start is not null then
          v_serial := v_serial_start + v_created_books;
          if exists (select 1 from public.books where serial_number = v_serial) then
            raise exception '일련번호 %가 이미 사용 중입니다. 다른 시작 번호를 입력해 주세요.', v_serial;
          end if;
        else
          v_serial := public._next_book_serial();
        end if;
        insert into public.books (
          shipment_id, title, option, product_id, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at, serial_number, location
        ) values (
          p_shipment_id, v_prod.title, v_optname, v_product_id, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now(), v_serial, v_location
        );
        v_created_books := v_created_books + 1;
        v_created_serials := v_created_serials || v_serial;
      end loop;
    end loop;
  end loop;

  -- 수동 시작 배정 시 시퀀스가 뒤처지지 않게 동기화 (자동 채번 exists 루프 비용 방지)
  if v_serial_start is not null and v_created_books > 0 then
    perform setval('public.books_serial_number_seq',
      greatest(
        (select last_value from public.books_serial_number_seq),
        (v_serial_start + v_created_books - 1)::bigint
      ));
  end if;

  return jsonb_build_object(
    'success', true,
    'created_products', v_created_products,
    'created_books', v_created_books,
    'created_serials', to_jsonb(v_created_serials)
  );
end;
$$;

notify pgrst, 'reload schema';

commit;
