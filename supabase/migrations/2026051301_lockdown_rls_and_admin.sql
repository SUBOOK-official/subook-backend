-- 묶음 1: D-2 보안/Race 차단
--   1. admin_users uuid 기반 전환 + is_admin_user() 새 정의
--   2. orders/pickup_requests UPDATE/INSERT 정책 회수 (회원은 RPC 전용)
--   3. cart_items WITH CHECK 추가 (user_id 변조 방지)
--   4. member_coupons unique(coupon_id, user_id) 부분 인덱스
--   5. create_order에 FOR UPDATE 락 + 동일 책 active order 검출

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) admin_users uuid 전환
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.admin_users
  add column if not exists user_id uuid;

-- 기존 6명 admin을 auth.users 매핑으로 채움 (대소문자 무시)
update public.admin_users a
set user_id = u.id
from auth.users u
where lower(u.email) = lower(a.email)
  and a.user_id is null;

-- 매핑 안된 row가 있으면 즉시 fail (위 사전 점검에서는 6명 모두 매핑 OK)
do $$
declare
  v_missing int;
begin
  select count(*) into v_missing
  from public.admin_users where user_id is null;
  if v_missing > 0 then
    raise exception 'admin_users user_id 매핑 누락: %건. 마이그레이션 중단.', v_missing;
  end if;
end;
$$;

alter table public.admin_users
  alter column user_id set not null;

create unique index if not exists idx_admin_users_user_id
  on public.admin_users (user_id);

-- is_admin_user() 새 정의: user_id 기반 + service_role 통과
create or replace function public.is_admin_user()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    coalesce(auth.role() = 'service_role', false)
    or exists (
      select 1 from public.admin_users where user_id = auth.uid()
    );
$$;

grant execute on function public.is_admin_user() to authenticated, anon, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) orders / pickup_requests UPDATE/INSERT 정책 회수
--    회원은 RPC(create_order, cancel_member_order, submit_pickup_request,
--    cancel_pickup_request)만 사용. RPC는 security definer로 RLS 우회.
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists "orders_insert_own" on public.orders;
drop policy if exists "orders_update_own" on public.orders;
-- SELECT는 유지 (회원 본인 주문 조회)

drop policy if exists "pickup_requests_insert_own" on public.pickup_requests;
drop policy if exists "pickup_requests_update_own" on public.pickup_requests;
-- pickup_requests_select_own / admin_all 은 유지

-- pickup_items도 같이 차단
drop policy if exists "pickup_items_insert_own" on public.pickup_items;
drop policy if exists "pickup_items_update_own" on public.pickup_items;
drop policy if exists "pickup_items_delete_own" on public.pickup_items;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) cart_items: WITH CHECK 추가 (user_id 변조 차단)
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists "cart_items_update_own" on public.cart_items;
create policy "cart_items_update_own" on public.cart_items
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) member_coupons unique(coupon_id, user_id)
-- ─────────────────────────────────────────────────────────────────────────────
create unique index if not exists idx_member_coupons_unique_user_coupon
  on public.member_coupons (coupon_id, user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) create_order: FOR UPDATE 락 + 동일 책 active order 검출
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

  v_item_count := array_length(p_book_ids, 1);
  if v_item_count is null or v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;
  if array_length(p_quantities, 1) <> v_item_count then
    raise exception 'book_ids and quantities must have same length';
  end if;

  -- 소계 계산 + 동일 책 동시 결제 차단
  for v_idx in 1..v_item_count loop
    -- ⚠️ FOR UPDATE 행 락: 두 결제가 동시에 같은 책에 들어오면 한 명만 진행
    select * into v_book from public.books
    where id = p_book_ids[v_idx] and status = 'on_sale' and is_public = true
    for update;
    if v_book is null then
      raise exception 'Book % is not available', p_book_ids[v_idx];
    end if;

    -- 동일 책에 이미 active(cancelled/refunded 아닌) order_items가 있는지 검증
    -- (도중에 다른 결제가 commit된 후 우리가 락 잡는 케이스 방어)
    select count(*) into v_active_count
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = v_book.id
      and o.status not in ('cancelled', 'refunded');
    if v_active_count > 0 then
      raise exception 'Book % is already reserved by another order', v_book.id;
    end if;

    v_subtotal := v_subtotal + (coalesce(v_book.price, 0) * p_quantities[v_idx]);
  end loop;

  if v_subtotal >= v_free_shipping_threshold then
    v_shipping_fee := 0;
  end if;

  -- 쿠폰 적용 (선택)
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
