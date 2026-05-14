-- 출시 직전 P0 핫픽스
--
-- 1. cancel_member_order: products.status='on_sale' CHECK 위반 제거
--    (products.status는 'selling'/'sold_out'/'hidden'만 허용. 'on_sale'은 books.status 값)
-- 2. create_order: pending 주문이 같은 책의 다른 결제 차단하던 문제 해결
--    (active 검사에서 'pending' 제외. paid 전이 시점 재검증은 admin_confirm_payment에서 처리.)
-- 3. create_order: payment_method를 'bank_transfer'로 강제 (PG 미연동)
-- 4. expire_old_coupons: authenticated 권한 회수 (service_role만)
-- 5. _admin_all RLS 정책 WITH CHECK 추가 (defense-in-depth)
-- 6. pickup_logistics_events_select_own 제거 (CJ 원본 응답 회원 노출 차단)
-- 7. is_admin_user() anon 권한 회수

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) cancel_member_order: products.status 업데이트 블록 제거
--    create_order 시 products.status를 변경하지 않으므로 cancel 시 되돌릴 필요 없음
-- ─────────────────────────────────────────────────────────────────────────────
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

  perform public.assert_member_not_blocked();

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

grant execute on function public.cancel_member_order(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) create_order: pending 제외 + payment_method 강제 + member_block 가드 유지
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

  -- PG 미연동: 현재는 계좌이체만 (클라이언트 우회 차단)
  if coalesce(p_payment_method, 'bank_transfer') <> 'bank_transfer' then
    raise exception '현재는 계좌이체만 지원합니다.';
  end if;

  v_item_count := array_length(p_book_ids, 1);
  if v_item_count is null or v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;
  if array_length(p_quantities, 1) <> v_item_count then
    raise exception 'book_ids and quantities must have same length';
  end if;

  for v_idx in 1..v_item_count loop
    select * into v_book from public.books
    where id = p_book_ids[v_idx] and status = 'on_sale' and is_public = true
    for update;
    if v_book is null then
      raise exception 'Book % is not available', p_book_ids[v_idx];
    end if;

    -- pending(미입금) 주문은 active로 보지 않음 → 다른 사용자도 시도 가능
    -- paid 전이 시점에 admin_confirm_payment가 active 재검증
    select count(*) into v_active_count
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = v_book.id
      and o.status not in ('cancelled', 'refunded', 'pending');
    if v_active_count > 0 then
      raise exception 'Book % is already reserved by another order', v_book.id;
    end if;

    v_subtotal := v_subtotal + (coalesce(v_book.price, 0) * p_quantities[v_idx]);
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
      p_quantities[v_idx], coalesce(v_book.price, 0),
      coalesce(v_book.price, 0) * p_quantities[v_idx]
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
    'shipping_fee', v_shipping_fee,
    'discount_amount', coalesce(v_discount, 0),
    'coupon_discount_amount', coalesce(v_discount, 0)
  );
end;
$$;

grant execute on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint
) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) expire_old_coupons: authenticated 권한 회수
-- ─────────────────────────────────────────────────────────────────────────────
revoke execute on function public.expire_old_coupons() from public;
revoke execute on function public.expire_old_coupons() from authenticated;
grant execute on function public.expire_old_coupons() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) _admin_all RLS 정책에 WITH CHECK 추가 (defense-in-depth)
--    이미 WITH CHECK 있는 것도 drop + recreate로 통일 (무해)
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists "cart_items_admin_all" on public.cart_items;
create policy "cart_items_admin_all" on public.cart_items
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "orders_admin_all" on public.orders;
create policy "orders_admin_all" on public.orders
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "order_items_admin_all" on public.order_items;
create policy "order_items_admin_all" on public.order_items
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "pickup_requests_admin_all" on public.pickup_requests;
create policy "pickup_requests_admin_all" on public.pickup_requests
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "pickup_items_admin_all" on public.pickup_items;
create policy "pickup_items_admin_all" on public.pickup_items
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "notification_logs_admin_all" on public.notification_logs;
create policy "notification_logs_admin_all" on public.notification_logs
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "settlements_admin_all" on public.settlements;
create policy "settlements_admin_all" on public.settlements
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "coupons_admin_all" on public.coupons;
create policy "coupons_admin_all" on public.coupons
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

drop policy if exists "member_coupons_admin_all" on public.member_coupons;
create policy "member_coupons_admin_all" on public.member_coupons
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- reviews 테이블은 P3 영역이며 환경에 따라 존재 여부 다름 → 가드 처리
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'reviews'
  ) then
    execute 'drop policy if exists "reviews_admin_all" on public.reviews';
    execute 'create policy "reviews_admin_all" on public.reviews
      for all to authenticated
      using (public.is_admin_user())
      with check (public.is_admin_user())';
  end if;
end $$;

drop policy if exists "book_change_logs_admin_all" on public.book_change_logs;
create policy "book_change_logs_admin_all" on public.book_change_logs
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) pickup_logistics_events: 회원 SELECT 정책 제거 (CJ 원본 응답 차단)
--    회원은 get_my_pickup_requests RPC로 안전 필드만 받음
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists pickup_logistics_events_select_own on public.pickup_logistics_events;

drop policy if exists pickup_logistics_events_admin_all on public.pickup_logistics_events;
create policy pickup_logistics_events_admin_all
  on public.pickup_logistics_events
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) is_admin_user() anon 권한 회수
-- ─────────────────────────────────────────────────────────────────────────────
revoke execute on function public.is_admin_user() from anon;
-- authenticated, service_role 유지

commit;
