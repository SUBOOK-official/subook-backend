-- 출시 차단급 P0 핫픽스 — Phase 2: 단일재고/가격 무결성 + 구매자 환불 신청
--
-- 1) cart_items.quantity = 1 강제 (단일재고 모델: 1 books row = 1 physical book).
--    99까지 허용하던 CHECK + 99 stepper로 인해 1권 책을 N권 주문해 과청구 가능.
-- 2) add_to_cart RPC: p_quantity를 무시하고 1로 고정 (방어).
-- 3) create_order RPC: 각 item의 quantity > 1을 거부 (방어). 기존 본체에 가드 한 줄만 추가.
-- 4) cart_items per user 100개 상한 (DoS 방어, Audit A의 P1).
-- 5) orders에 refund_request 필드 + member_request_refund / member_cancel_refund_request RPC.
--    전자상거래법 7일 청약철회권 대응 (Audit B의 P0).

begin;

-- ============================================================================
-- 1) cart_items.quantity = 1 강제
-- ============================================================================
update public.cart_items set quantity = 1 where quantity <> 1;

alter table public.cart_items drop constraint if exists cart_items_quantity_check;
alter table public.cart_items
  add constraint cart_items_quantity_check check (quantity = 1);

-- ============================================================================
-- 2) add_to_cart: 항상 quantity=1로 강제 (signature 유지 — p_quantity 무시)
-- ============================================================================
create or replace function public.add_to_cart(
  p_book_id bigint,
  p_product_id bigint default null,
  p_quantity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_cart_id bigint;
  v_cart_count integer;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  -- 단일재고 모델: quantity는 항상 1
  -- cart 개수 상한 (DoS 방어): 100개 초과 시 거부
  select count(*) into v_cart_count
    from public.cart_items
   where user_id = v_user_id;

  if v_cart_count >= 100
     and not exists (
       select 1 from public.cart_items
        where user_id = v_user_id and book_id = p_book_id
     )
  then
    raise exception '장바구니에 담을 수 있는 최대 개수(100)를 초과했습니다.';
  end if;

  insert into public.cart_items (user_id, book_id, product_id, quantity)
  values (v_user_id, p_book_id, p_product_id, 1)
  on conflict (user_id, book_id) do update
    set quantity = 1,
        updated_at = now()
  returning id into v_cart_id;

  return jsonb_build_object('cart_item_id', v_cart_id);
end;
$$;

-- ============================================================================
-- 3) create_order: quantity > 1 거부 (방어 — 프론트가 보내더라도 차단)
--    2026051308의 create_order 본체 전체를 그대로 유지하면서 quantity 검증 1줄만 추가.
-- ============================================================================
create or replace function public.create_order(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'bank_transfer',
  p_member_coupon_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_order_id bigint;
  v_order_number text;
  v_subtotal integer := 0;
  v_shipping_fee integer := 3500;
  v_discount integer := 0;
  v_total_amount integer;
  v_item_count integer;
  v_idx integer;
  v_book record;
  v_member_coupon record;
  v_coupon record;
  v_used_count integer;
  v_free_shipping_threshold integer := 30000;
  v_active_count integer;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  v_item_count := array_length(p_book_ids, 1);
  if v_item_count is null or v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;
  if array_length(p_quantities, 1) <> v_item_count then
    raise exception 'book_ids and quantities must have same length';
  end if;

  for v_idx in 1..v_item_count loop
    -- ⚠️ 단일재고 모델 가드: 한 books row는 1권. 항상 quantity=1만 허용.
    if coalesce(p_quantities[v_idx], 0) <> 1 then
      raise exception '교재 한 권만 주문할 수 있습니다. (book_id=%, quantity=%)',
        p_book_ids[v_idx], p_quantities[v_idx];
    end if;

    select * into v_book from public.books
    where id = p_book_ids[v_idx] and status = 'on_sale' and is_public = true
    for update;
    if v_book is null then
      raise exception 'Book % is not available', p_book_ids[v_idx];
    end if;

    select count(*) into v_active_count
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = v_book.id
      and o.status not in ('cancelled', 'refunded');
    if v_active_count > 0 then
      raise exception 'Book % is already reserved by another order', v_book.id;
    end if;

    v_subtotal := v_subtotal + coalesce(v_book.price, 0);
  end loop;

  if v_subtotal >= v_free_shipping_threshold then
    v_shipping_fee := 0;
  end if;

  if p_member_coupon_id is not null then
    select * into v_member_coupon
    from public.member_coupons
    where id = p_member_coupon_id and user_id = v_user_id
    for update;
    if not found then
      raise exception '선택한 쿠폰을 찾을 수 없습니다.';
    end if;
    if v_member_coupon.status <> 'available' then
      raise exception '사용 가능한 쿠폰이 아닙니다.';
    end if;
    if v_member_coupon.expires_at is not null and v_member_coupon.expires_at < now() then
      raise exception '만료된 쿠폰입니다.';
    end if;

    select * into v_coupon from public.coupons where id = v_member_coupon.coupon_id;
    if not v_coupon.is_active then
      raise exception '비활성된 쿠폰입니다.';
    end if;
    if v_coupon.min_order_amount > v_subtotal then
      raise exception '최소 주문 금액(%원)을 만족하지 않습니다.', v_coupon.min_order_amount;
    end if;

    if v_coupon.usage_limit_per_user is not null then
      select count(*) into v_used_count from public.member_coupons mc2
      where mc2.user_id = v_user_id
        and mc2.coupon_id = v_coupon.id
        and mc2.status = 'used';
      if v_used_count >= v_coupon.usage_limit_per_user then
        raise exception '쿠폰 사용 한도를 초과했습니다.';
      end if;
    end if;

    if v_coupon.discount_type = 'fixed' then
      v_discount := least(v_coupon.discount_value, v_subtotal);
    elsif v_coupon.discount_type = 'percentage' then
      v_discount := (v_subtotal * v_coupon.discount_value) / 100;
      if v_coupon.max_discount_amount is not null then
        v_discount := least(v_discount, v_coupon.max_discount_amount);
      end if;
    elsif v_coupon.discount_type = 'free_shipping' then
      if v_subtotal >= v_free_shipping_threshold then
        raise exception '이 쿠폰은 무료배송 조건을 이미 충족한 주문엔 사용할 수 없습니다.';
      end if;
      v_discount := v_shipping_fee;
      v_shipping_fee := 0;
    end if;
  end if;

  if p_member_coupon_id is not null and v_coupon.discount_type = 'free_shipping' then
    v_total_amount := v_subtotal + v_shipping_fee;
  else
    v_total_amount := v_subtotal + v_shipping_fee - v_discount;
  end if;
  if v_total_amount < 0 then v_total_amount := 0; end if;

  v_order_number := public.generate_order_number();

  insert into public.orders (
    user_id, order_number, status,
    shipping_recipient_name, shipping_recipient_phone,
    shipping_postal_code, shipping_address_line1, shipping_address_line2, shipping_memo,
    payment_method, payment_status,
    subtotal, shipping_fee, discount_amount, total_amount, item_count,
    auto_confirm_at,
    applied_member_coupon_id, coupon_discount_amount
  ) values (
    v_user_id, v_order_number, 'pending',
    p_shipping_recipient_name, p_shipping_recipient_phone,
    p_shipping_postal_code, p_shipping_address_line1, p_shipping_address_line2, p_shipping_memo,
    p_payment_method, 'pending',
    v_subtotal, v_shipping_fee, coalesce(v_discount, 0), v_total_amount, v_item_count,
    null,
    p_member_coupon_id,
    coalesce(v_discount, 0)
  ) returning id into v_order_id;

  for v_idx in 1..v_item_count loop
    select * into v_book from public.books where id = p_book_ids[v_idx];
    insert into public.order_items (
      order_id, book_id, product_id,
      title, option_label, condition_grade, cover_image_url,
      quantity, unit_price, total_price
    ) values (
      v_order_id, v_book.id, v_book.product_id,
      v_book.title, v_book.option, v_book.condition_grade, v_book.cover_image_url,
      1, coalesce(v_book.price, 0),
      coalesce(v_book.price, 0)
    );
  end loop;

  if p_member_coupon_id is not null then
    update public.member_coupons
    set used_at = now(), used_order_id = v_order_id
    where id = p_member_coupon_id;
  end if;

  delete from public.cart_items
  where user_id = v_user_id and book_id = any(p_book_ids);

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'total_amount', v_total_amount,
    'subtotal', v_subtotal,
    'shipping_fee', v_shipping_fee,
    'discount_amount', coalesce(v_discount, 0),
    'coupon_discount_amount', coalesce(v_discount, 0)
  );
end;
$$;

-- ============================================================================
-- 5) 구매자 환불 신청 (전자상거래법 7일 청약철회권)
--    delivered / confirmed 상태에서 신청 가능. 어드민 검토 후 admin_refund_order 호출.
-- ============================================================================
alter table public.orders
  add column if not exists refund_requested_at timestamptz null,
  add column if not exists refund_request_reason text null;

create index if not exists idx_orders_refund_requested
  on public.orders (refund_requested_at)
  where refund_requested_at is not null;

create or replace function public.request_member_refund(
  p_order_id bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order public.orders%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_now timestamptz := now();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if v_reason is null or length(v_reason) < 4 then
    raise exception '환불 사유는 4자 이상 입력해주세요.';
  end if;

  select * into v_order
    from public.orders
   where id = p_order_id and user_id = v_user_id
   for update;

  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status not in ('delivered', 'confirmed') then
    raise exception '배송완료 또는 구매확정 상태에서만 환불을 신청할 수 있습니다. (현재: %)', v_order.status;
  end if;

  if v_order.refund_requested_at is not null then
    raise exception '이미 환불 신청이 접수되었습니다. (접수일: %)', to_char(v_order.refund_requested_at, 'YYYY-MM-DD HH24:MI');
  end if;

  -- 배송완료 후 7일 이내만 (전자상거래법)
  if v_order.status = 'delivered' then
    -- delivered_at이 없을 수도 있어서 updated_at fallback
    if coalesce(v_order.updated_at, v_order.created_at) < (v_now - interval '7 days') then
      raise exception '배송완료 후 7일이 지나 환불 신청이 어렵습니다. 고객센터에 문의해주세요.';
    end if;
  end if;

  update public.orders
     set refund_requested_at = v_now,
         refund_request_reason = v_reason,
         updated_at = v_now
   where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'requested_at', v_now,
    'reason', v_reason
  );
end;
$$;

grant execute on function public.request_member_refund(bigint, text) to authenticated;

-- 구매자가 환불 신청을 철회할 수 있도록 (admin이 처리하기 전까지만)
create or replace function public.cancel_member_refund_request(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order public.orders%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_order
    from public.orders
   where id = p_order_id and user_id = v_user_id
   for update;

  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.refund_requested_at is null then
    raise exception '환불 신청 내역이 없습니다.';
  end if;

  if v_order.status = 'refunded' then
    raise exception '이미 환불 처리된 주문입니다.';
  end if;

  update public.orders
     set refund_requested_at = null,
         refund_request_reason = null,
         updated_at = now()
   where id = p_order_id;

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

grant execute on function public.cancel_member_refund_request(bigint) to authenticated;

-- list_admin_orders에서 refund_requested_at을 노출하도록 — admin이 처리 대기 큐를 볼 수 있도록.
-- (RPC 본체는 다른 마이그레이션에서 정의. 여기서는 column 노출만 보장)
-- 어드민은 service_role / is_admin_user() 권한으로 orders 직접 select 가능. 추가 RPC 불필요.

commit;
