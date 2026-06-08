-- 무료배송 컷 30,000원 -> 50,000원.
-- 현재 prod의 create_order / get_applicable_coupons 정의를 그대로 가져와
-- v_free_shipping_threshold 상수만 50000으로 치환(다른 로직 변경 없음). 프론트 cart.js와 일치.
-- 비파괴: CREATE OR REPLACE FUNCTION(시그니처 동일, grant 유지).

-- create_order: v_free_shipping_threshold 30000 -> 50000
CREATE OR REPLACE FUNCTION public.create_order(p_book_ids bigint[], p_quantities integer[], p_shipping_recipient_name text, p_shipping_recipient_phone text, p_shipping_postal_code text, p_shipping_address_line1 text, p_shipping_address_line2 text, p_shipping_memo text, p_payment_method text DEFAULT 'bank_transfer'::text, p_member_coupon_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_product_cover text;
  v_member_coupon record;
  v_coupon record;
  v_used_count integer;
  v_free_shipping_threshold integer := 50000;
  v_active_count integer;
  v_is_free_shipping_coupon boolean := false;
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
      v_is_free_shipping_coupon := true;
    end if;
  end if;

  if v_is_free_shipping_coupon then
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

    -- ⚠ cover_image_url fallback — 식스샵 import 책은 books.cover_image_url이
    --   NULL이고 products.cover_image_url에만 cover가 있음.
    select p.cover_image_url into v_product_cover
    from public.products p
    where p.id = v_book.product_id;

    insert into public.order_items (
      order_id, book_id, product_id,
      title, option_label, condition_grade, cover_image_url,
      quantity, unit_price, total_price
    ) values (
      v_order_id, v_book.id, v_book.product_id,
      v_book.title, v_book.option, v_book.condition_grade,
      coalesce(
        nullif(btrim(v_book.cover_image_url), ''),
        nullif(btrim(v_product_cover), '')
      ),
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
$function$
;

-- get_applicable_coupons: v_free_shipping_threshold 30000 -> 50000
CREATE OR REPLACE FUNCTION public.get_applicable_coupons(p_subtotal integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
  v_free_shipping_threshold integer := 50000;
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
$function$
;

notify pgrst, 'reload schema';
