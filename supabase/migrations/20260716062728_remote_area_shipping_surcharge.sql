-- 제주·도서산간 배송 추가비 +5,000원 실과금 (2026-07-16 사용자 확정)
--
-- 배경: 상품 상세 배송 안내는 "제주 +5,000 / 도서산간 +5,000"을 명시하는데
-- create_order는 우편번호 기반 추가비를 계산하지 않아 카피≠청구 상태였고,
-- 도서산간 주문의 추가 운임을 수북이 흡수하고 있었다.
--
-- 정책:
--   - 추가비는 기본 배송비와 별개 — 무료배송 임계(5만원) 충족·무료배송 쿠폰
--     사용 시에도 부과된다 (쿠폰 처리 후 가산하는 순서로 구현).
--   - 판정 범위는 확실한 것만 우선 적용: 제주(63000–63644) + 울릉·독도(40200–40240).
--     기타 도서 지역은 CJ 공식 도서산간 우편번호 목록 확보 후
--     get_remote_area_surcharge에 범위만 추가하면 됨 (클라이언트 미러
--     frontend/apps/public-web/src/lib/remoteAreaShipping.js 와 세트로 수정).
--
-- create_order는 시그니처 동일(13인자) 순수 CREATE OR REPLACE.
-- 반환 jsonb에 remote_area_surcharge 추가 (체크아웃 표시용).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 도서산간 판정 함수
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_remote_area_surcharge(p_postal_code text)
returns integer
language plpgsql
immutable
parallel safe
as $$
declare
  v_code integer;
begin
  v_code := nullif(regexp_replace(coalesce(p_postal_code, ''), '[^0-9]', '', 'g'), '')::integer;
  if v_code is null then
    return 0;
  end if;

  -- 제주특별자치도
  if v_code between 63000 and 63644 then
    return 5000;
  end if;

  -- 울릉군(울릉도·독도)
  if v_code between 40200 and 40240 then
    return 5000;
  end if;

  return 0;
exception when others then
  -- 우편번호 파싱 실패는 추가비 없음으로 (주문 차단 금지)
  return 0;
end;
$$;

grant execute on function public.get_remote_area_surcharge(text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) create_order 재정의 — 추가비 가산 (쿠폰 처리 후)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_order(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'bank_transfer'::text,
  p_member_coupon_id bigint default null::bigint,
  p_refund_bank text default null,
  p_refund_account_number text default null,
  p_refund_account_holder text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_order_id bigint;
  v_order_number text;
  v_subtotal integer := 0;
  v_shipping_fee integer := 3000;
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
  v_remote_surcharge integer := 0;
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

  -- 제주·도서산간 추가비 — 무료배송(임계·쿠폰) 처리 "이후" 가산해
  -- 어떤 경우에도 추가 운임은 부과된다 (상세 배송 안내 카피와 일치)
  v_remote_surcharge := public.get_remote_area_surcharge(p_shipping_postal_code);
  v_shipping_fee := v_shipping_fee + v_remote_surcharge;

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
    applied_member_coupon_id, coupon_discount_amount,
    refund_bank_name, refund_account_number, refund_account_holder
  ) values (
    v_user_id, v_order_number, 'pending',
    p_shipping_recipient_name, p_shipping_recipient_phone,
    p_shipping_postal_code, p_shipping_address_line1, p_shipping_address_line2, p_shipping_memo,
    p_payment_method, 'pending',
    v_subtotal, v_shipping_fee, coalesce(v_discount, 0), v_total_amount, v_item_count,
    null,
    p_member_coupon_id,
    coalesce(v_discount, 0),
    nullif(btrim(coalesce(p_refund_bank, '')), ''),
    nullif(regexp_replace(coalesce(p_refund_account_number, ''), '[^0-9]', '', 'g'), ''),
    nullif(btrim(coalesce(p_refund_account_holder, '')), '')
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
    'remote_area_surcharge', v_remote_surcharge,
    'discount_amount', coalesce(v_discount, 0),
    'coupon_discount_amount', coalesce(v_discount, 0)
  );
end;
$function$;

grant execute on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
) to authenticated;

notify pgrst, 'reload schema';
