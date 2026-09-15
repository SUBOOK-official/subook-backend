-- 수북 자체 판매 교재 설정 + 상품 등록 판매 내역 (2026-09-15)
--
-- 1) 수북 자체 판매 교재(전일학원 콜라보 신품 등)는 창고 위치·일련번호·상세 사진이 없는 게 정상이다.
--    상품 단위로 지정해 재고 점검(위치 미지정·일련번호 없음·상세 사진 없음)과 주문 화면의
--    위치 미지정 표시에서 제외한다. 판매가 없음·판매중 비노출·표지 없음 점검은 그대로 적용.
--    products에 컬럼을 늘리지 않고 별도 테이블로 둔다(products 행을 통째 반환하는 함수 영향 차단).
-- 2) 상품 등록 '기존 교재 재고 추가'에서 가격을 정할 때 참고할 실제 판매 내역과
--    같은 교재의 다른 연도·중복 상품 현황을 조회한다.
--
-- ⚠ 재정의 시 유지 필수:
--   · admin_list_products_with_inventory — locations 집계, 일련번호 정확 일치 검색, p_issue·issues, is_direct_sale
--   · list_admin_orders — items의 books 조인·book_serial_number/book_location/book_status, product_id·is_direct_sale
--   · _admin_inventory_book_flags — 자체 판매 교재의 위치·일련번호·상세사진 제외

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 자체 판매 교재 목록
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.direct_sale_products (
  product_id bigint primary key references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

comment on table public.direct_sale_products is
  '수북 자체 판매 교재(콜라보 신품 등). 재고 점검의 위치·일련번호·상세 사진 누락과 주문 화면 위치 미지정 표시에서 제외. 관리자 RPC로만 읽고 쓴다.';

alter table public.direct_sale_products enable row level security;
-- 정책 없음: anon·authenticated 직접 접근 차단, 관리자 SECURITY DEFINER RPC만 사용
revoke all on table public.direct_sale_products from anon, authenticated;

create or replace function public.admin_set_product_direct_sale(p_product_id bigint, p_is_direct_sale boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  if coalesce(p_is_direct_sale, false) then
    insert into public.direct_sale_products (product_id) values (p_product_id)
    on conflict (product_id) do nothing;
  else
    delete from public.direct_sale_products where product_id = p_product_id;
  end if;

  return jsonb_build_object(
    'product_id', p_product_id,
    'is_direct_sale', exists (select 1 from public.direct_sale_products where product_id = p_product_id)
  );
end;
$$;

revoke all on function public.admin_set_product_direct_sale(bigint, boolean) from public, anon;
grant execute on function public.admin_set_product_direct_sale(bigint, boolean) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 점검 플래그 — 자체 판매 교재는 위치·일련번호·상세 사진 제외
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._admin_inventory_book_flags()
returns table (
  book_id bigint,
  product_id bigint,
  is_on_sale boolean,
  picking_pending boolean,
  missing_location boolean,
  missing_serial boolean,
  missing_detail_photo boolean,
  missing_price boolean,
  hidden_on_sale boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    b.id,
    b.product_id,
    b.status = 'on_sale',
    coalesce(pending.hit, false),
    ds.product_id is null and nullif(btrim(b.location), '') is null,
    ds.product_id is null and b.serial_number is null,
    ds.product_id is null and b.status = 'on_sale' and coalesce(cardinality(b.inspection_image_urls), 0) = 0,
    b.status = 'on_sale' and coalesce(b.price, 0) <= 0,
    b.status = 'on_sale' and b.is_public is not true
  from public.books b
  left join public.direct_sale_products ds on ds.product_id = b.product_id
  left join lateral (
    select exists (
      select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.book_id = b.id
        and oi.refunded_at is null
        and o.status in ('pending', 'paid', 'preparing')
    ) as hit
  ) pending on b.status = 'reserved'
  where b.product_id is not null
    and (b.status = 'on_sale' or coalesce(pending.hit, false));
$$;

revoke all on function public._admin_inventory_book_flags() from public, anon, authenticated;
grant execute on function public._admin_inventory_book_flags() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 상품 목록 — is_direct_sale 필드 추가 (나머지는 20260915053213과 동일)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_list_products_with_inventory(
  p_search text default null,
  p_brand text default null,
  p_subject text default null,
  p_book_type text default null,
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0,
  p_sort text default 'updated',
  p_issue text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_total integer;
  v_sort text;
  v_issue text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 알 수 없는 값은 기본(updated)으로 정규화
  v_sort := case when p_sort = 'created' then 'created' else 'updated' end;
  -- 알 수 없는 점검 항목은 필터 없음으로 취급
  v_issue := case
    when p_issue in ('any', 'missing_location', 'missing_serial', 'missing_detail_photo',
                     'missing_price', 'hidden_on_sale', 'missing_cover') then p_issue
    else null
  end;

  with iss as (
    select
      f.product_id,
      count(*) filter (where f.missing_location)::integer as missing_location,
      count(*) filter (where f.missing_location and f.picking_pending)::integer as missing_location_pending,
      count(*) filter (where f.missing_serial)::integer as missing_serial,
      count(*) filter (where f.missing_detail_photo)::integer as missing_detail_photo,
      count(*) filter (where f.missing_price)::integer as missing_price,
      count(*) filter (where f.hidden_on_sale)::integer as hidden_on_sale,
      count(*) filter (where f.is_on_sale)::integer as on_sale
    from public._admin_inventory_book_flags() f
    group by f.product_id
  )
  select count(*)::integer
  into v_total
  from public.products p
  left join iss on iss.product_id = p.id
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
  and (
    v_issue is null
    or (v_issue = 'missing_location' and coalesce(iss.missing_location, 0) > 0)
    or (v_issue = 'missing_serial' and coalesce(iss.missing_serial, 0) > 0)
    or (v_issue = 'missing_detail_photo' and coalesce(iss.missing_detail_photo, 0) > 0)
    or (v_issue = 'missing_price' and coalesce(iss.missing_price, 0) > 0)
    or (v_issue = 'hidden_on_sale' and coalesce(iss.hidden_on_sale, 0) > 0)
    or (v_issue = 'missing_cover' and coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
    or (v_issue = 'any' and (
      coalesce(iss.missing_location, 0) + coalesce(iss.missing_serial, 0) + coalesce(iss.missing_detail_photo, 0)
        + coalesce(iss.missing_price, 0) + coalesce(iss.hidden_on_sale, 0) > 0
      or (coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
    ))
  );

  with iss as (
    select
      f.product_id,
      count(*) filter (where f.missing_location)::integer as missing_location,
      count(*) filter (where f.missing_location and f.picking_pending)::integer as missing_location_pending,
      count(*) filter (where f.missing_serial)::integer as missing_serial,
      count(*) filter (where f.missing_detail_photo)::integer as missing_detail_photo,
      count(*) filter (where f.missing_price)::integer as missing_price,
      count(*) filter (where f.hidden_on_sale)::integer as hidden_on_sale,
      count(*) filter (where f.is_on_sale)::integer as on_sale
    from public._admin_inventory_book_flags() f
    group by f.product_id
  )
  select coalesce(jsonb_agg(row_data
    order by
      (case when v_sort = 'created' then row_data->>'created_at' else row_data->>'updated_at' end) desc nulls last,
      (row_data->>'id')::bigint desc), '[]'::jsonb)
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
      'locations', coalesce(to_jsonb(inv.locations), '[]'::jsonb),
      -- 수북 자체 판매 교재 (2026-09-15) — 위치·일련번호·상세사진 점검 제외 대상
      'is_direct_sale', exists (select 1 from public.direct_sale_products ds where ds.product_id = p.id),
      'issues', jsonb_build_object(
        'missing_location', coalesce(iss.missing_location, 0),
        'missing_location_pending', coalesce(iss.missing_location_pending, 0),
        'missing_serial', coalesce(iss.missing_serial, 0),
        'missing_detail_photo', coalesce(iss.missing_detail_photo, 0),
        'missing_price', coalesce(iss.missing_price, 0),
        'hidden_on_sale', coalesce(iss.hidden_on_sale, 0),
        'missing_cover', coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null
      )
    ) as row_data
    from public.products p
    left join iss on iss.product_id = p.id
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
    and (
      v_issue is null
      or (v_issue = 'missing_location' and coalesce(iss.missing_location, 0) > 0)
      or (v_issue = 'missing_serial' and coalesce(iss.missing_serial, 0) > 0)
      or (v_issue = 'missing_detail_photo' and coalesce(iss.missing_detail_photo, 0) > 0)
      or (v_issue = 'missing_price' and coalesce(iss.missing_price, 0) > 0)
      or (v_issue = 'hidden_on_sale' and coalesce(iss.hidden_on_sale, 0) > 0)
      or (v_issue = 'missing_cover' and coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
      or (v_issue = 'any' and (
        coalesce(iss.missing_location, 0) + coalesce(iss.missing_serial, 0) + coalesce(iss.missing_detail_photo, 0)
          + coalesce(iss.missing_price, 0) + coalesce(iss.hidden_on_sale, 0) > 0
        or (coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
      ))
    )
    order by
      (case when v_sort = 'created' then p.created_at else p.updated_at end) desc nulls last,
      p.id desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 상품 상세(권별 현황) — product에 is_direct_sale 추가
-- ─────────────────────────────────────────────────────────────────────────────
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

  select to_jsonb(p) || jsonb_build_object(
    'is_direct_sale', exists (select 1 from public.direct_sale_products ds where ds.product_id = p.id)
  )
  into v_product
  from public.products p where p.id = p_product_id;
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
    'location', b.location,
    'detail_photo_count', coalesce(cardinality(b.inspection_image_urls), 0),
    'picking_pending', b.status = 'reserved' and exists (
      select 1
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.book_id = b.id
        and oi.refunded_at is null
        and o.status in ('pending', 'paid', 'preparing')
    )
  ) order by s.seller_name nulls last, b.option nulls last, b.id), '[]'::jsonb)
  into v_books
  from public.books b
  left join public.shipments s on s.id = b.shipment_id
  where b.product_id = p_product_id;

  return jsonb_build_object('product', v_product, 'books', v_books);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. 주문 목록 — 품목에 product_id·is_direct_sale 추가 (나머지는 운영 정의 그대로)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_admin_orders(p_search text DEFAULT NULL::text, p_statuses text[] DEFAULT NULL::text[], p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
      o.shipping_recipient_name ilike '%' || p_search || '%' or
      o.shipping_recipient_phone ilike '%' || p_search || '%')
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
      -- 포인트 사용액 (2026-09-02 포인트 제도 — total_amount에 이미 차감 반영)
      'points_used', coalesce(o.points_used, 0),
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
      -- 환불 신청 해소 시각 (2026-08-24 자동확정 보류 — null이면 확정·송금 보류 중)
      'refund_request_resolved_at', o.refund_request_resolved_at,
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- 반품 수거 3종 (2026-08-24 반품 수거 자동화 — cust_use_no는 서버 전용이라 미노출)
      'return_tracking_number', o.return_tracking_number,
      'return_registered_at', o.return_registered_at,
      'return_recovered_at', o.return_recovered_at,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      -- 비회원 주문 여부 (2026-08-03 게스트 주문 도입)
      'is_guest', (o.user_id is null),
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
          -- 품목별 환불 상태 (2026-08-01 부분환불)
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount,
          'refund_reason', oi.refund_reason,
          -- 재입고 보류 (2026-08-24 반품 수거 — 실물 회수 전 재노출 방지)
          'restock_held_at', oi.restock_held_at,
          -- 피킹 동선용 재고 메타 (2026-07-18: 위치로 가서 일련번호로 실물 확인)
          'book_serial_number', b.serial_number,
          'book_location', b.location,
          'book_status', b.status,
          -- 수북 자체 판매 교재 품목은 위치·일련번호가 없는 게 정상 (2026-09-15)
          'product_id', oi.product_id,
          'is_direct_sale', exists (select 1 from public.direct_sale_products ds where ds.product_id = oi.product_id)
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
        o.shipping_recipient_name ilike '%' || p_search || '%' or
        o.shipping_recipient_phone ilike '%' || p_search || '%')
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= p_from_date)
      and (p_to_date is null or o.created_at < p_to_date + interval '1 day')
    order by
      -- 미해소 환불 신청 최우선 (해소된 신청은 일반 정렬)
      (case
        when o.refund_requested_at is not null
         and o.refund_request_resolved_at is null
         and o.status <> 'refunded' then 0
        else 1
      end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. 상품 등록 참고 — 판매 내역 + 같은 교재의 다른 연도·중복 상품
--    판매 = 결제 완료 주문 품목(환불 제외, 주문 당시 옵션·가격·등급)
--         + 식스샵/수동 정산(같은 권의 주문 판매와 중복 제외).
--    admin_search_products_for_register 의 판매 집계 규칙과 같다.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_get_register_sales_history(p_product_id bigint, p_limit integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_title_key text;
  v_sales jsonb;
  v_sales_count integer;
  v_similar jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 앞의 학년도와 공백을 뺀 제목 키 (예: '2026 시대인재 …' ↔ '2025 시대인재 …')
  select lower(regexp_replace(regexp_replace(p.title, '^\s*20[0-9]{2}\s*', ''), '\s+', '', 'g'))
  into v_title_key
  from public.products p where p.id = p_product_id;
  if v_title_key is null then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  with paid_sales as (
    select 'order'::text as source, oi.book_id, nullif(btrim(oi.option_label), '') as option_label,
      oi.condition_grade, oi.unit_price as price, coalesce(o.paid_at, o.created_at) as sold_at
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where oi.product_id = p_product_id and oi.refunded_at is null and oi.unit_price > 0
      and o.payment_status = 'paid'
      and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
  ),
  sales as (
    select source, option_label, condition_grade, price, sold_at from paid_sales
    union all
    select 'manual', nullif(btrim(b.option), ''), b.condition_grade, ms.sale_amount,
      coalesce(ms.sold_at::timestamptz, ms.created_at)
    from public.manual_settlements ms
    join public.books b on b.id = ms.book_id
    where b.product_id = p_product_id and b.status = 'settled'
      and ms.status <> 'cancelled' and ms.sale_amount > 0
      and not exists (select 1 from paid_sales s where s.book_id = b.id)
  ),
  recent as (
    select * from sales order by sold_at desc nulls last
    limit greatest(1, least(coalesce(p_limit, 30), 100))
  )
  select
    (select count(*)::integer from sales),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'source', r.source, 'option', r.option_label, 'grade', r.condition_grade,
        'price', r.price, 'sold_at', r.sold_at
      ) order by r.sold_at desc nulls last)
      from recent r
    ), '[]'::jsonb)
  into v_sales_count, v_sales;

  select coalesce(jsonb_agg(row_data order by (row_data->>'stock_count')::integer desc, (row_data->>'id')::bigint), '[]'::jsonb)
  into v_similar
  from (
    select jsonb_build_object(
      'id', p.id,
      'title', p.title,
      'stock_count', count(b.id) filter (where b.status = 'on_sale'),
      'min_price', min(b.price) filter (where b.status = 'on_sale' and b.price > 0),
      'max_price', max(b.price) filter (where b.status = 'on_sale' and b.price > 0),
      'options', coalesce(
        array_agg(distinct nullif(btrim(b.option), ''))
          filter (where b.status = 'on_sale' and nullif(btrim(b.option), '') is not null),
        '{}'::text[]),
      'locations', coalesce(
        array_agg(distinct b.location) filter (where b.status = 'on_sale' and b.location is not null),
        '{}'::text[]),
      'sold_count', count(b.id) filter (where b.status in ('reserved', 'settled'))
    ) as row_data
    from public.products p
    left join public.books b on b.product_id = p.id
    where p.id <> p_product_id
      and lower(regexp_replace(regexp_replace(p.title, '^\s*20[0-9]{2}\s*', ''), '\s+', '', 'g')) = v_title_key
    group by p.id, p.title
    limit 5
  ) sibling;

  return jsonb_build_object(
    'sales', v_sales,
    'sales_count', coalesce(v_sales_count, 0),
    'similar_products', v_similar
  );
end;
$$;

revoke all on function public.admin_get_register_sales_history(bigint, integer) from public, anon;
grant execute on function public.admin_get_register_sales_history(bigint, integer) to authenticated, service_role;

commit;
