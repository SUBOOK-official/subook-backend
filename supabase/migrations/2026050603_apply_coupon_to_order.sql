-- 쿠폰 시스템 PR 3: 주문 적용 + 취소 시 자동 복구
-- 정책 (PR 1 합의):
--  - 주문당 쿠폰 1개만
--  - percentage는 subtotal에만 (배송비 별도)
--  - 무료배송 + 임계금액 도달 = 적용 막음
--  - 취소 시 자동 복구
--  - usage_limit_per_user는 사용 횟수 기준

-- 1) orders에 쿠폰 적용 컬럼 추가
alter table public.orders
  add column if not exists applied_member_coupon_id bigint null
    references public.member_coupons(id) on delete set null;

alter table public.orders
  add column if not exists coupon_discount_amount integer not null default 0;

-- 음수 방어 (기존 행은 default 0으로 들어감)
alter table public.orders drop constraint if exists orders_coupon_discount_nonneg;
alter table public.orders add constraint orders_coupon_discount_nonneg
  check (coupon_discount_amount >= 0);

create index if not exists idx_orders_applied_member_coupon
  on public.orders (applied_member_coupon_id);

-- 2) 주문 적용 가능한 쿠폰 목록
-- p_subtotal: 검토할 주문의 subtotal (배송비 미포함)
-- 무료배송 임계금액(30,000원) 이상이면 free_shipping 쿠폰은 제외 (이미 무료라 의미 없음)
create or replace function public.get_applicable_coupons(p_subtotal integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
  v_free_shipping_threshold integer := 30000;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'issued_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', mc.id,
      'coupon_id', mc.coupon_id,
      'title', c.title,
      'description', c.description,
      'discount_type', c.discount_type,
      'discount_value', c.discount_value,
      'max_discount_amount', c.max_discount_amount,
      'min_order_amount', c.min_order_amount,
      'expires_at', mc.expires_at,
      'issued_at', mc.issued_at
    ) as row_data
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    where mc.user_id = v_user_id
      and mc.status = 'available'
      and (mc.expires_at is null or mc.expires_at >= now())
      and c.is_active = true
      and c.min_order_amount <= p_subtotal
      and (
        -- 무료배송 쿠폰은 임계금액 미만일 때만 적용 가능
        c.discount_type <> 'free_shipping'
        or p_subtotal < v_free_shipping_threshold
      )
      and (
        -- usage_limit_per_user 초과 시 제외
        c.usage_limit_per_user is null
        or (
          select count(*) from public.member_coupons mc2
          where mc2.user_id = v_user_id
            and mc2.coupon_id = c.id
            and mc2.status = 'used'
        ) < c.usage_limit_per_user
      )
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.get_applicable_coupons(integer) to authenticated;

-- 3) create_order: p_member_coupon_id 파라미터 추가하면서 함수 시그니처 변경
-- 시그니처가 바뀌므로 기존 함수를 drop하고 재작성
drop function if exists public.create_order(bigint[], integer[], text, text, text, text, text, text, text);

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
  v_discount integer := 0;  -- subtotal에 적용되는 할인 (free_shipping은 shipping_fee로 별도 처리)
  v_total_amount integer;
  v_item_count integer;
  v_idx integer;
  v_book record;
  v_member_coupon record;
  v_coupon record;
  v_used_count integer;
  v_free_shipping_threshold integer := 30000;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  v_item_count := array_length(p_book_ids, 1);
  if v_item_count is null or v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;
  if array_length(p_quantities, 1) <> v_item_count then
    raise exception 'book_ids and quantities must have same length';
  end if;

  -- 소계 계산
  for v_idx in 1..v_item_count loop
    select * into v_book from public.books
    where id = p_book_ids[v_idx] and status = 'on_sale' and is_public = true;
    if v_book is null then
      raise exception 'Book % is not available', p_book_ids[v_idx];
    end if;
    v_subtotal := v_subtotal + (coalesce(v_book.price, 0) * p_quantities[v_idx]);
  end loop;

  if v_subtotal >= v_free_shipping_threshold then
    v_shipping_fee := 0;
  end if;

  -- ── 쿠폰 적용 (선택) ────────────────────────────────────────────
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

    -- 할인 계산
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
      -- subtotal 할인은 0, shipping_fee를 0으로
      v_discount := v_shipping_fee;  -- coupon_discount_amount에 기록할 값
      v_shipping_fee := 0;
    end if;
  end if;

  -- ── total 계산 ────────────────────────────────────────────────
  -- free_shipping은 v_shipping_fee를 0으로 만들었으니 subtotal에서 또 빼면 안 됨
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
    v_user_id, v_order_number, 'paid',
    p_shipping_recipient_name, p_shipping_recipient_phone,
    p_shipping_postal_code, p_shipping_address_line1, p_shipping_address_line2, p_shipping_memo,
    p_payment_method, 'paid',
    v_subtotal, v_shipping_fee, coalesce(v_discount, 0), v_total_amount, v_item_count,
    now() + interval '7 days',
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
      p_quantities[v_idx], coalesce(v_book.price, 0),
      coalesce(v_book.price, 0) * p_quantities[v_idx]
    );
  end loop;

  -- 쿠폰 사용 마킹 (트리거가 status='used'로 자동 갱신)
  if p_member_coupon_id is not null then
    update public.member_coupons
    set used_at = now(), used_order_id = v_order_id
    where id = p_member_coupon_id;
  end if;

  -- 장바구니 정리
  delete from public.cart_items
  where user_id = v_user_id and book_id = any(p_book_ids);

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'subtotal', v_subtotal,
    'shipping_fee', v_shipping_fee,
    'coupon_discount_amount', coalesce(v_discount, 0),
    'total_amount', v_total_amount,
    'item_count', v_item_count
  );
end;
$$;

grant execute on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint
) to authenticated;

-- 4) cancel_member_order: 쿠폰 자동 복구
create or replace function public.cancel_member_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_order record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_order from public.orders where id = p_order_id and user_id = v_user_id;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status not in ('pending', 'paid', 'preparing') then
    raise exception '입금대기 / 결제완료 / 상품 준비 중 상태에서만 취소가 가능합니다. (현재: %)', v_order.status;
  end if;

  update public.orders
  set
    status = 'cancelled',
    payment_status = case when v_order.payment_status = 'paid' then 'refunded' else payment_status end,
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  -- 상품 재고 복구
  update public.products
  set status = 'on_sale', updated_at = now()
  where id in (
    select product_id from public.order_items where order_id = p_order_id and product_id is not null
  );

  -- 쿠폰 자동 복구
  if v_order.applied_member_coupon_id is not null then
    update public.member_coupons
    set used_at = null,
        used_order_id = null,
        status = case
          when expires_at is not null and expires_at < now() then 'expired'
          else 'available'
        end
    where id = v_order.applied_member_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

-- 5) admin_update_order_status: 어드민 취소 시에도 쿠폰 복구
create or replace function public.admin_update_order_status(
  p_order_id bigint,
  p_status text,
  p_tracking_number text default null,
  p_tracking_carrier text default 'CJ대한통운'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found';
  end if;

  if p_status = 'paid' and v_order.status not in ('pending') then
    raise exception 'Cannot mark as paid from status: %', v_order.status;
  end if;
  if p_status = 'preparing' and v_order.status not in ('paid') then
    raise exception 'Cannot mark as preparing from status: %', v_order.status;
  end if;
  if p_status = 'shipping' and v_order.status not in ('paid', 'preparing') then
    raise exception 'Cannot mark as shipping from status: %', v_order.status;
  end if;
  if p_status = 'delivered' and v_order.status not in ('shipping') then
    raise exception 'Cannot mark as delivered from status: %', v_order.status;
  end if;
  if p_status = 'cancelled' and v_order.status not in ('pending', 'paid', 'preparing') then
    raise exception 'Cannot cancel from status: %', v_order.status;
  end if;

  update public.orders
  set
    status = p_status,
    payment_status = case when p_status = 'paid' then 'paid' when p_status = 'cancelled' then 'refunded' else payment_status end,
    tracking_number = coalesce(p_tracking_number, tracking_number),
    tracking_carrier = coalesce(p_tracking_carrier, tracking_carrier),
    confirmed_at = case when p_status = 'confirmed' then now() else confirmed_at end,
    auto_confirm_at = case when p_status = 'delivered' then now() + interval '7 days' else auto_confirm_at end,
    updated_at = now()
  where id = p_order_id;

  -- 어드민 취소 시 쿠폰 자동 복구
  if p_status = 'cancelled' and v_order.applied_member_coupon_id is not null then
    update public.member_coupons
    set used_at = null,
        used_order_id = null,
        status = case
          when expires_at is not null and expires_at < now() then 'expired'
          else 'available'
        end
    where id = v_order.applied_member_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'order_id', p_order_id, 'new_status', p_status);
end;
$$;
