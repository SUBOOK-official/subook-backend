-- 재고 실사 이관: books에 일련번호(serial_number)·창고 위치(location) 도입 + admin RPC 노출
--
-- 배경(2026-07-18): 실물 재고는 구글시트 "새 DB(330~)"가 원본 — 책마다 일련번호 라벨을
--   붙이고 위치 코드(A1~A10, B1~B10, C1~C11, C상, 모1~모10)로 선반을 관리하며,
--   주문이 오면 위치로 가서 일련번호로 실물을 찾아 포장한다. 이 운영 체계를 DB로 이관한다.
--
--   * books.serial_number : 실물 고유 일련번호. 시트 2,084행은 별도 백필로 이관,
--                           신규 등록분은 books_serial_number_seq로 자동 채번.
--   * books.location      : 창고 선반 코드(자유 텍스트, NFKC 정규화 — 전각 Ｃ 등 통일).
--
-- 변경 요약 (비파괴: 컬럼 추가 + 인덱스 + CREATE OR REPLACE):
--   1) books 컬럼 2종 + CHECK + 부분 유니크 인덱스 + 시퀀스 + _next_book_serial() 헬퍼
--   2) admin_get_product_inventory      : 권별 serial_number/location 노출
--   3) admin_list_products_with_inventory: on_sale 위치 요약(locations) + 일련번호 정확 검색
--   4) list_admin_orders                : 주문 아이템에 book_serial_number/book_location/book_status
--                                         (피킹 동선 — 20260713043458 최신 정의 + 3필드)
--   5) admin_register_customer_inventory: 신규 책 일련번호 자동 채번 + 위치 입력(payload item.location),
--                                         created_serials 반환 (20260713070629 최신 정의 기반)
--   6) admin_update_book_inventory_meta : 권별 일련번호/위치 수정 (신설)
--
-- 백필은 push 후 별도 실행(시트↔books 매칭 결과 기반 UPDATE + 시퀀스 setval).

begin;

-- ── 1) 컬럼 · 인덱스 · 시퀀스 ─────────────────────────────────────────────

alter table public.books
  add column if not exists serial_number integer null,
  add column if not exists location text null;

comment on column public.books.serial_number is '실물 일련번호 (창고 라벨 번호, 신규는 books_serial_number_seq 자동 채번)';
comment on column public.books.location is '창고 위치 코드 (예: A1, B7, C상, 모10)';

alter table public.books drop constraint if exists books_serial_number_positive_check;
alter table public.books add constraint books_serial_number_positive_check
  check (serial_number is null or serial_number > 0);

create unique index if not exists idx_books_serial_number_unique
  on public.books (serial_number)
  where serial_number is not null;

create index if not exists idx_books_location
  on public.books (location)
  where location is not null;

create sequence if not exists public.books_serial_number_seq;

-- 다음 일련번호 채번. 시퀀스가 실제 max보다 뒤처져 있어도(수동 배정 등) 유니크 충돌 없이
-- 건너뛰도록 exists 가드 루프를 둔다.
create or replace function public._next_book_serial()
returns integer
language plpgsql
as $$
declare
  v integer;
begin
  loop
    v := nextval('public.books_serial_number_seq')::integer;
    exit when not exists (select 1 from public.books where serial_number = v);
  end loop;
  return v;
end;
$$;

-- ── 2) admin_get_product_inventory: 권별 일련번호/위치 노출 ─────────────────
-- (2026050617 최신 정의 + serial_number/location 2필드)

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
    'created_at', b.created_at,
    'serial_number', b.serial_number,
    'location', b.location
  ) order by s.seller_name nulls last, b.option nulls last, b.id), '[]'::jsonb)
  into v_books
  from public.books b
  left join public.shipments s on s.id = b.shipment_id
  where b.product_id = p_product_id;

  return jsonb_build_object('product', v_product, 'books', v_books);
end;
$$;

-- ── 3) admin_list_products_with_inventory: 위치 요약 + 일련번호 검색 ────────
-- (20260518091835 최신 정의 + locations 집계 + 숫자 검색어의 일련번호 정확 일치)

create or replace function public.admin_list_products_with_inventory(
  p_search text default null,
  p_brand text default null,
  p_subject text default null,
  p_book_type text default null,
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_total integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
  from public.products p
  where (
    p_search is null or p_search = '' or
    p.title ilike '%' || p_search || '%' or
    coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
    coalesce(p.option, '') ilike '%' || p_search || '%' or
    (p_search ~ '^\d+$' and length(p_search) <= 9 and exists (
      select 1 from public.books bs
      where bs.product_id = p.id and bs.serial_number = p_search::integer
    ))
  )
  and (p_brand is null or p_brand = '' or p.brand = p_brand)
  and (p_subject is null or p_subject = '' or p.subject = p_subject)
  and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
  and (p_status is null or p_status = '' or p.status = p_status);

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', p.id,
      'group_key', p.group_key,
      'title', p.title,
      'option', p.option,
      'subject', p.subject,
      'brand', p.brand,
      'book_type', p.book_type,
      'published_year', p.published_year,
      'instructor_name', p.instructor_name,
      'cover_image_url', p.cover_image_url,
      'status', p.status,
      'created_at', p.created_at,
      'updated_at', p.updated_at,
      'inventory_count', coalesce(inv.on_sale_count, 0),
      'public_count', coalesce(inv.public_count, 0),
      'total_book_count', coalesce(inv.total_count, 0),
      'min_price', inv.min_price,
      'max_price', inv.max_price,
      'locations', coalesce(to_jsonb(inv.locations), '[]'::jsonb)
    ) as row_data
    from public.products p
    left join lateral (
      select
        count(*) filter (where b.status = 'on_sale') as on_sale_count,
        count(*) filter (where b.status = 'on_sale' and b.is_public = true) as public_count,
        count(*) as total_count,
        min(b.price) filter (where b.status = 'on_sale') as min_price,
        max(b.price) filter (where b.status = 'on_sale') as max_price,
        array_agg(distinct b.location order by b.location)
          filter (where b.status = 'on_sale' and b.location is not null) as locations
      from public.books b
      where b.product_id = p.id
    ) inv on true
    where (
      p_search is null or p_search = '' or
      p.title ilike '%' || p_search || '%' or
      coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
      coalesce(p.option, '') ilike '%' || p_search || '%' or
      (p_search ~ '^\d+$' and length(p_search) <= 9 and exists (
        select 1 from public.books bs
        where bs.product_id = p.id and bs.serial_number = p_search::integer
      ))
    )
    and (p_brand is null or p_brand = '' or p.brand = p_brand)
    and (p_subject is null or p_subject = '' or p.subject = p_subject)
    and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
    and (p_status is null or p_status = '' or p.status = p_status)
    order by p.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

-- ── 4) list_admin_orders: 주문 아이템에 피킹용 재고 메타 ────────────────────
-- (20260713043458 최신 정의 + books 조인, book_serial_number/book_location/book_status)

create or replace function public.list_admin_orders(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_total integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
  from public.orders o
  left join public.member_profiles p on p.user_id = o.user_id
  where
    (p_search is null or p_search = '' or
      o.order_number ilike '%' || p_search || '%' or
      p.name ilike '%' || p_search || '%' or
      p.email ilike '%' || p_search || '%' or
      p.phone ilike '%' || p_search || '%' or
      o.shipping_recipient_name ilike '%' || p_search || '%')
    and (p_statuses is null or o.status = any(p_statuses))
    and (p_from_date is null or o.created_at >= p_from_date)
    and (p_to_date is null or o.created_at < p_to_date + interval '1 day');

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      -- 결제 확인 시각 2종 (2026-07-13: 무통장=paid_at, 레거시 PG=pg_approved_at 폴백)
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      -- 할인 필드 3종 (2026-07-06 피드백: 주문 상세에 쿠폰 사용액 표시)
      'discount_amount', o.discount_amount,
      'coupon_discount_amount', o.coupon_discount_amount,
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'shipping_recipient_name', o.shipping_recipient_name,
      'shipping_recipient_phone', o.shipping_recipient_phone,
      'shipping_postal_code', o.shipping_postal_code,
      'shipping_address_line1', o.shipping_address_line1,
      'shipping_address_line2', o.shipping_address_line2,
      'shipping_memo', o.shipping_memo,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      -- 환불 메타 4종
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      'buyer_email', p.email,
      'buyer_name', p.name,
      'buyer_phone', p.phone,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          -- 피킹 동선용 재고 메타 (2026-07-18: 위치로 가서 일련번호로 실물 확인)
          'book_serial_number', b.serial_number,
          'book_location', b.location,
          'book_status', b.status
        ) order by oi.id)
        from public.order_items oi
        left join public.books b on b.id = oi.book_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    left join public.member_profiles p on p.user_id = o.user_id
    where
      (p_search is null or p_search = '' or
        o.order_number ilike '%' || p_search || '%' or
        p.name ilike '%' || p_search || '%' or
        p.email ilike '%' || p_search || '%' or
        p.phone ilike '%' || p_search || '%' or
        o.shipping_recipient_name ilike '%' || p_search || '%')
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= p_from_date)
      and (p_to_date is null or o.created_at < p_to_date + interval '1 day')
    order by
      (case when o.refund_requested_at is not null and o.status <> 'refunded' then 0 else 1 end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

-- ── 5) admin_register_customer_inventory: 자동 채번 + 위치 입력 ─────────────
-- (20260713070629 최신 정의 + serial_number 자동 채번, payload item.location,
--  created_serials 반환. 시그니처 동일 — 구버전 프론트 payload도 그대로 동작)

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
      v_serial := public._next_book_serial();
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
        v_serial := public._next_book_serial();
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

  return jsonb_build_object(
    'success', true,
    'created_products', v_created_products,
    'created_books', v_created_books,
    'created_serials', to_jsonb(v_created_serials)
  );
end;
$$;

-- ── 6) admin_update_book_inventory_meta: 권별 일련번호/위치 수정 (신설) ──────
-- p_serial_number/p_location이 null이면 기존 값 유지, 비우려면 clear 플래그 사용.

create or replace function public.admin_update_book_inventory_meta(
  p_book_id bigint,
  p_serial_number integer default null,
  p_location text default null,
  p_clear_serial boolean default false,
  p_clear_location boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_book public.books%rowtype;
  v_serial integer;
  v_location text;
  v_conflict bigint;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_book from public.books where id = p_book_id;
  if not found then
    raise exception '책을 찾을 수 없습니다.';
  end if;

  v_serial := case when p_clear_serial then null else coalesce(p_serial_number, v_book.serial_number) end;
  v_location := case
    when p_clear_location then null
    else coalesce(nullif(normalize(btrim(coalesce(p_location, '')), nfkc), ''), v_book.location)
  end;

  if v_serial is not null and v_serial <= 0 then
    raise exception '일련번호는 1 이상의 숫자여야 합니다.';
  end if;

  if v_serial is not null then
    select id into v_conflict
    from public.books
    where serial_number = v_serial and id <> p_book_id
    limit 1;
    if v_conflict is not null then
      raise exception '일련번호 %는 이미 다른 책(#%)에 배정되어 있습니다.', v_serial, v_conflict;
    end if;
  end if;

  update public.books
  set serial_number = v_serial,
      location = v_location
  where id = p_book_id;

  return jsonb_build_object(
    'success', true,
    'book_id', p_book_id,
    'serial_number', v_serial,
    'location', v_location
  );
end;
$$;

notify pgrst, 'reload schema';

commit;
