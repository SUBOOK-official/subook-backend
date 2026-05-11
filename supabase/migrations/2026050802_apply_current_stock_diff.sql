-- 2026-05-11 현재 창고 재고 엑셀을 진실의 원천으로 삼고 DB를 일괄 보정.
-- 입력 JSON:
--   purchasing_seller_name: '수북 자체 매입'
--   new_books: [{ seller, title, option, price, writing_pct, sold_flag }, ...]
--     - seller=='매입' → 수북 자체 매입 가상 shipment에 INSERT
--     - seller가 있는데 기존 shipment 없으면 새 shipment 자동 생성
--   settled_ids: bigint[]  → status='settled'
--   sold_out_ids: bigint[] → status='sold_out'
--
-- 트리거 우회 후 일괄 처리, 마지막에 product_id 자동 link (title+option).

create or replace function public.admin_apply_current_stock_diff(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_purchasing_shipment_id bigint;
  v_today date := current_date;
  v_inserted integer := 0;
  v_settled integer := 0;
  v_sold_out integer := 0;
  v_linked integer := 0;
  v_skipped integer := 0;
  v_new_shipments_created integer := 0;
  v_record jsonb;
  v_seller text;
  v_title text;
  v_option text;
  v_price integer;
  v_writing_pct integer;
  v_sold_flag text;
  v_condition_grade text;
  v_target_shipment_id bigint;
  v_book_status text;
  v_settled_ids bigint[];
  v_sold_out_ids bigint[];
begin
  if not (public.is_admin_user() or auth.role() = 'service_role') then
    raise exception 'Admin or service_role required';
  end if;

  alter table public.books disable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books disable trigger books_refresh_storefront_product_status_trigger;

  -- 1) 수북 자체 매입 가상 shipment (있으면 reuse)
  select id into v_purchasing_shipment_id
  from public.shipments
  where seller_name = '수북 자체 매입'
  limit 1;

  if v_purchasing_shipment_id is null then
    insert into public.shipments (seller_name, seller_phone, pickup_date, status)
    values ('수북 자체 매입', '', v_today, 'inspected')
    returning id into v_purchasing_shipment_id;
  end if;

  -- 2) 새 books INSERT (셀러별 shipment 자동 매칭/생성)
  for v_record in select * from jsonb_array_elements(p_payload->'new_books') loop
    v_seller := nullif(btrim(v_record->>'seller'), '');
    v_title := nullif(btrim(v_record->>'title'), '');
    v_option := nullif(btrim(v_record->>'option'), '');
    v_price := nullif(v_record->>'price', '')::integer;
    v_writing_pct := nullif(v_record->>'writing_pct', '')::integer;
    v_sold_flag := v_record->>'sold_flag';
    v_condition_grade := nullif(btrim(v_record->>'condition_grade'), '');

    if v_title is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- 셀러 매칭
    if v_seller is null or v_seller = '매입' then
      v_target_shipment_id := v_purchasing_shipment_id;
    else
      -- 기존 shipment 가장 작은 id 사용 (가장 처음 등록된 묶음)
      select id into v_target_shipment_id
      from public.shipments
      where seller_name = v_seller
      order by id asc
      limit 1;

      if v_target_shipment_id is null then
        -- 새 셀러 → 새 shipment 자동 생성
        insert into public.shipments (seller_name, seller_phone, pickup_date, status)
        values (v_seller, '', v_today, 'inspected')
        returning id into v_target_shipment_id;
        v_new_shipments_created := v_new_shipments_created + 1;
      end if;
    end if;

    -- status: 엑셀이 '판매완료'면 settled, 그 외 on_sale
    v_book_status := case when v_sold_flag = '판매완료' then 'settled' else 'on_sale' end;

    insert into public.books (
      shipment_id, title, option, price,
      writing_percentage, status, condition_grade
    )
    values (
      v_target_shipment_id, v_title, v_option, v_price,
      v_writing_pct, v_book_status, v_condition_grade
    );
    v_inserted := v_inserted + 1;
  end loop;

  -- 3) settled_ids → status='settled'
  if p_payload ? 'settled_ids' then
    select array(select (jsonb_array_elements_text(p_payload->'settled_ids'))::bigint) into v_settled_ids;
    update public.books set status = 'settled' where id = any(v_settled_ids);
    get diagnostics v_settled = row_count;
  end if;

  -- 4) sold_out_ids → status='sold_out'
  if p_payload ? 'sold_out_ids' then
    select array(select (jsonb_array_elements_text(p_payload->'sold_out_ids'))::bigint) into v_sold_out_ids;
    update public.books set status = 'sold_out' where id = any(v_sold_out_ids);
    get diagnostics v_sold_out = row_count;
  end if;

  -- 5) product_id 자동 매칭 (title+option 정확, 그 후 title only)
  update public.books b
  set product_id = p.id
  from public.products p
  where b.product_id is null
    and lower(btrim(b.title)) = lower(btrim(p.title))
    and lower(btrim(coalesce(b.option, ''))) = lower(btrim(coalesce(p.option, '')));
  get diagnostics v_linked = row_count;

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
  -- v_linked는 step 5의 첫 단계만 카운트 (충분)

  -- 6) 새로 link된 books의 메타데이터를 product에서 reverse-copy
  update public.books b
  set
    subject = coalesce(b.subject, p.subject),
    brand = coalesce(b.brand, p.brand),
    book_type = coalesce(b.book_type, p.book_type),
    published_year = coalesce(b.published_year, p.published_year),
    instructor_name = coalesce(b.instructor_name, p.instructor_name)
  from public.products p
  where b.product_id = p.id
    and (b.subject is null or b.brand is null or b.book_type is null);

  -- 7) 새로 INSERT된 books의 condition_grade가 NULL이면 옵션 텍스트로 재계산
  update public.books
  set condition_grade = case
    when option ~ 'A\+' then 'A_PLUS'
    when option ~ '(\s|-)\s*A([^A-Za-z+]|$)' then 'A'
    else 'S'
  end
  where condition_grade is null;

  alter table public.books enable trigger books_enforce_public_storefront_rules_trigger;
  alter table public.books enable trigger books_refresh_storefront_product_status_trigger;

  return jsonb_build_object(
    'purchasing_shipment_id', v_purchasing_shipment_id,
    'inserted', v_inserted,
    'skipped', v_skipped,
    'new_shipments_created', v_new_shipments_created,
    'settled', v_settled,
    'sold_out', v_sold_out,
    'linked_to_product', v_linked
  );
end;
$$;
