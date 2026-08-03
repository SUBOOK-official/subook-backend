-- 카드(PG) 결제 '선주문 생성' 폐지 — 결제 완료 후에만 주문 생성 (2026-08-03)
--
-- 배경(운영 버그 리포트): 카드 결제창을 열기 위해 pending 주문을 먼저 만들다 보니,
--   결제창을 그냥 닫고 이탈하면 ① 주문이 '입금대기'로 마이페이지에 남고
--   ② 책이 reserved로 30~45분 선점(품절 표시)되고 ③ 장바구니는 이미 비워져
--   본인이 같은 책을 다시 사려 해도 품절로 보이는 문제(한태경 사례).
--
-- 변경: 카드 결제는 주문 대신 "결제 세션"(pg_checkout_sessions)만 만든다.
--   세션은 재고를 선점하지 않고 회원에게 보이지도 않는다. 카드 인증이 성공하면
--   returnUrl 서버리스(nicepay-return)가 finalize_pg_checkout_session으로 그때
--   주문을 생성하고, 주문 생성이 성공한 경우에만 승인 API를 호출한다.
--   (인증 단계만으로는 청구가 발생하지 않으므로, 주문 생성 실패 = 승인 미진행 = 청구 없음)
--
-- 구성 (비파괴 — 신규 테이블/함수 + CREATE OR REPLACE):
--   1) pg_checkout_sessions 테이블 (RLS on·정책 없음 = definer RPC/service_role 전용)
--   2) create_order_core: 기존 create_order 본문 추출.
--      p_user_id 명시(서비스롤 경로), p_order_number 지정(세션 번호 재사용),
--      p_validate_only(검증·금액계산만) 파라미터 추가. 검증·가드는 기존과 동일:
--      차단회원 거부·권당 1권·on_sale+is_public·active order 충돌·쿠폰 규칙·도서산간 추가비.
--   3) create_order: 시그니처·동작 동일(13인자) — core 위임 래퍼.
--      assert_member_not_blocked() 가드 유지(재정의 시에도 유지 필수).
--   4) create_pg_checkout_session(13인자, authenticated): 검증 통과 시 세션 생성.
--   5) finalize_pg_checkout_session(service_role 전용): 세션 스냅샷으로 주문 실체화.
--      재고·쿠폰·금액은 이 시점에 전부 재검증 — 실패하면 exception(주문 없음, 승인 금지).
--   6) expire_unpaid_orders: 오래된 세션(24h) 청소 추가. 기존 규칙(무통장 24h 만료·
--      리마인더·카드 pending 30분 만료)은 그대로 유지 — 30분 룰은 이제
--      "finalize 후 승인 전 서버 크래시"로 남은 고아 pending의 백스톱.
--
-- 무통장(bank_transfer) 주문 흐름은 변경 없음 (주문 즉시 생성 = 입금대기가 정상).

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) pg_checkout_sessions — 카드 결제 세션 (재고 미선점, 회원 비노출)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.pg_checkout_sessions (
  id bigint generated always as identity primary key,
  -- 나이스페이 orderId(moid)로 쓰이는 값. finalize 시 생성되는 주문의 order_number가 된다.
  order_number text not null unique,
  user_id uuid not null,
  -- create_order와 동일한 인자 스냅샷 (finalize에서 그대로 재생)
  payload jsonb not null,
  -- 세션 생성 시점에 서버가 확정한 결제 금액 = 결제창에 띄우는 금액
  expected_amount integer not null,
  status text not null default 'created',
  order_id bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pg_checkout_sessions_status_check check (status in ('created', 'completed'))
);

comment on table public.pg_checkout_sessions is
  '카드(PG) 결제 세션 — 결제창 오픈용 스냅샷. 주문은 카드 인증 성공 후 finalize가 생성. 세션 자체는 재고를 선점하지 않는다.';

create index if not exists idx_pg_checkout_sessions_created_at
  on public.pg_checkout_sessions (created_at);

-- RLS on + 정책 없음: anon/authenticated 직접 접근 전면 차단.
-- 접근 경로는 security definer RPC(아래 2종)와 service_role뿐.
alter table public.pg_checkout_sessions enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) create_order_core — create_order 본문 추출 (내부 전용)
--    base: 20260716062728_remote_area_shipping_surcharge.sql의 create_order 본문.
--    차이: v_user_id := p_user_id / 차단 가드를 user_id 명시 조회로(서비스롤 경로에서도
--    동작) / p_validate_only=true면 어떤 쓰기도 없이 검증·금액만 / p_order_number 지정 가능.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_order_core(
  p_user_id uuid,
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
  p_refund_account_holder text default null,
  p_order_number text default null,
  p_validate_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_blocked boolean;
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
  v_user_id := p_user_id;
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  -- 차단 회원 가드 — assert_member_not_blocked()는 auth.uid() 기반이라 service_role
  -- (finalize) 경로에서 no-op이 되므로, user_id 명시 조회로 양쪽 경로 모두 가드한다.
  select coalesce(mp.is_blocked, false) into v_blocked
  from public.member_profiles mp
  where mp.user_id = v_user_id;
  if coalesce(v_blocked, false) then
    raise exception '계정이 차단되어 해당 작업을 수행할 수 없습니다.';
  end if;

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

  -- 검증 전용 모드: 어떤 쓰기도 없이 금액 견적만 반환 (결제 세션 생성용)
  if p_validate_only then
    return jsonb_build_object(
      'order_id', null,
      'order_number', null,
      'total_amount', v_total_amount,
      'subtotal', v_subtotal,
      'shipping_fee', v_shipping_fee,
      'remote_area_surcharge', v_remote_surcharge,
      'discount_amount', coalesce(v_discount, 0),
      'coupon_discount_amount', coalesce(v_discount, 0)
    );
  end if;

  v_order_number := coalesce(nullif(btrim(coalesce(p_order_number, '')), ''), public.generate_order_number());

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

-- 내부 전용: 클라이언트 롤에서 직접 호출 금지 (definer RPC 경유만).
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean
) from public;
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean
) from anon;
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean
) from authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) create_order — 시그니처·동작 동일한 core 위임 래퍼 (무통장 주문 경로)
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
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  return public.create_order_core(
    v_user_id,
    p_book_ids,
    p_quantities,
    p_shipping_recipient_name,
    p_shipping_recipient_phone,
    p_shipping_postal_code,
    p_shipping_address_line1,
    p_shipping_address_line2,
    p_shipping_memo,
    p_payment_method,
    p_member_coupon_id,
    p_refund_bank,
    p_refund_account_number,
    p_refund_account_holder
  );
end;
$function$;

grant execute on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) create_pg_checkout_session — 카드 결제 세션 생성 (authenticated)
--    create_order와 동일 인자·동일 검증. 주문/재고 선점 없이 세션만 만든다.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_pg_checkout_session(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'card'::text,
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
  v_quote jsonb;
  v_order_number text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  -- 무통장은 세션 대상이 아님 — 주문 즉시 생성(입금대기) 정책 유지
  if coalesce(p_payment_method, 'bank_transfer') = 'bank_transfer' then
    raise exception 'PG 결제 수단만 결제 세션을 사용할 수 있습니다.';
  end if;

  -- create_order와 동일한 검증·금액 계산 (쓰기 없음)
  v_quote := public.create_order_core(
    v_user_id,
    p_book_ids,
    p_quantities,
    p_shipping_recipient_name,
    p_shipping_recipient_phone,
    p_shipping_postal_code,
    p_shipping_address_line1,
    p_shipping_address_line2,
    p_shipping_memo,
    p_payment_method,
    p_member_coupon_id,
    p_refund_bank,
    p_refund_account_number,
    p_refund_account_holder,
    p_order_number => null,
    p_validate_only => true
  );

  v_order_number := public.generate_order_number();

  insert into public.pg_checkout_sessions (order_number, user_id, payload, expected_amount)
  values (
    v_order_number,
    v_user_id,
    jsonb_build_object(
      'book_ids', to_jsonb(p_book_ids),
      'quantities', to_jsonb(p_quantities),
      'shipping_recipient_name', p_shipping_recipient_name,
      'shipping_recipient_phone', p_shipping_recipient_phone,
      'shipping_postal_code', p_shipping_postal_code,
      'shipping_address_line1', p_shipping_address_line1,
      'shipping_address_line2', p_shipping_address_line2,
      'shipping_memo', p_shipping_memo,
      'payment_method', p_payment_method,
      'member_coupon_id', p_member_coupon_id,
      'refund_bank', p_refund_bank,
      'refund_account_number', p_refund_account_number,
      'refund_account_holder', p_refund_account_holder
    ),
    coalesce((v_quote->>'total_amount')::integer, 0)
  );

  -- create_order와 동일한 필드 구성 + 세션 표시 (order_id는 아직 없음)
  return v_quote || jsonb_build_object(
    'order_number', v_order_number,
    'checkout_session', true
  );
end;
$function$;

revoke all on function public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
) from public;
revoke all on function public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
) from anon;
grant execute on function public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) finalize_pg_checkout_session — 카드 인증 성공 후 주문 실체화 (service_role 전용)
--    nicepay-return 서버리스가 "서명 검증을 통과한" 인증 성공 분기에서만 호출한다.
--    여기서 exception이 나면 주문은 만들어지지 않고, 호출자는 승인 API를 호출하지
--    않으므로 고객에게 청구되지 않는다.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.finalize_pg_checkout_session(
  p_order_number text,
  p_amount integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_session record;
  v_order record;
  v_result jsonb;
begin
  if p_order_number is null or btrim(p_order_number) = '' then
    return jsonb_build_object('success', false, 'reason', 'order_number_required');
  end if;

  select * into v_session
  from public.pg_checkout_sessions
  where order_number = p_order_number
  for update;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'session_not_found');
  end if;

  -- 멱등 처리: 중복 POST(새로고침·서버 재시도)면 이미 실체화된 주문 현황을 반환.
  -- 호출자는 payment_status='paid'면 완료 페이지로, 'pending'이면 승인 재개(크래시 복구).
  if v_session.status = 'completed' then
    select * into v_order from public.orders where id = v_session.order_id;
    if not found then
      return jsonb_build_object('success', false, 'reason', 'order_missing');
    end if;
    return jsonb_build_object(
      'success', true,
      'already_completed', true,
      'order_id', v_order.id,
      'order_number', v_order.order_number,
      'total_amount', v_order.total_amount,
      'order_status', v_order.status,
      'payment_status', v_order.payment_status
    );
  end if;

  -- 세션 수명 가드 — 나이스페이 인증 유효시간을 한참 넘긴 좀비 재생 차단
  if v_session.created_at < now() - interval '24 hours' then
    return jsonb_build_object('success', false, 'reason', 'session_expired');
  end if;

  -- 인증(청구 예정) 금액 = 세션 확정 금액인지 먼저 확인 (서명 검증된 값이지만 이중 방어)
  if p_amount is null or p_amount <> v_session.expected_amount then
    return jsonb_build_object(
      'success', false,
      'reason', 'amount_mismatch',
      'expected_amount', v_session.expected_amount
    );
  end if;

  -- 세션 스냅샷으로 주문 실체화 — 재고·쿠폰·가격은 이 시점에 전부 재검증된다.
  -- 결제창 진행 중 다른 주문이 책을 가져갔으면 여기서 exception → 승인 미진행.
  v_result := public.create_order_core(
    v_session.user_id,
    (
      select coalesce(array_agg(t.value::bigint order by t.ord), array[]::bigint[])
      from jsonb_array_elements_text(v_session.payload->'book_ids') with ordinality as t(value, ord)
    ),
    (
      select coalesce(array_agg(t.value::integer order by t.ord), array[]::integer[])
      from jsonb_array_elements_text(v_session.payload->'quantities') with ordinality as t(value, ord)
    ),
    v_session.payload->>'shipping_recipient_name',
    v_session.payload->>'shipping_recipient_phone',
    v_session.payload->>'shipping_postal_code',
    v_session.payload->>'shipping_address_line1',
    v_session.payload->>'shipping_address_line2',
    v_session.payload->>'shipping_memo',
    coalesce(v_session.payload->>'payment_method', 'card'),
    nullif(v_session.payload->>'member_coupon_id', '')::bigint,
    v_session.payload->>'refund_bank',
    v_session.payload->>'refund_account_number',
    v_session.payload->>'refund_account_holder',
    p_order_number => v_session.order_number,
    p_validate_only => false
  );

  -- 실체화된 주문 금액과 청구 금액 일치 확인 — 다르면 전체 롤백(승인 진행 금지).
  -- (세션 생성과 finalize 사이에 책 가격이 바뀐 극단 케이스 방어)
  if coalesce((v_result->>'total_amount')::integer, -1) <> p_amount then
    raise exception '주문 금액(%원)이 결제 예정 금액(%원)과 일치하지 않습니다.',
      coalesce((v_result->>'total_amount')::integer, 0), p_amount;
  end if;

  update public.pg_checkout_sessions
     set status = 'completed',
         order_id = (v_result->>'order_id')::bigint,
         updated_at = now()
   where id = v_session.id;

  return jsonb_build_object(
    'success', true,
    'already_completed', false,
    'order_id', (v_result->>'order_id')::bigint,
    'order_number', v_session.order_number,
    'total_amount', (v_result->>'total_amount')::integer,
    'order_status', 'pending',
    'payment_status', 'pending'
  );
end;
$function$;

revoke all on function public.finalize_pg_checkout_session(text, integer) from public;
revoke all on function public.finalize_pg_checkout_session(text, integer) from anon;
revoke all on function public.finalize_pg_checkout_session(text, integer) from authenticated;
grant execute on function public.finalize_pg_checkout_session(text, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) expire_unpaid_orders — 오래된 결제 세션 청소 추가
--    (base: 20260728121625 — 리마인더·무통장 24h·카드 30분 룰 전부 동일 유지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.expire_unpaid_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_count   integer := 0;
  v_coupon_restored integer := 0;
  v_reminded_count  integer := 0;
  v_sessions_purged integer := 0;
  v_iter_count      integer;
  v_order           record;
begin
  -- 1) 입금 마감 임박 리마인더 (마감 3시간 전 ~ 마감 전, 1회) — 무통장 전용
  with target as (
    select o.id, o.user_id, o.order_number, o.created_at
    from public.orders o
    where o.status = 'pending'
      and o.payment_status = 'pending'
      and coalesce(o.payment_method, 'bank_transfer') = 'bank_transfer'
      and o.payment_reminder_sent_at is null
      and o.user_id is not null
      and o.created_at < now() - interval '21 hours'
      and o.created_at >= now() - interval '24 hours'
    for update skip locked
  ),
  notified as (
    insert into public.member_notifications (user_id, type, title, body, ref_url, ref_type, ref_id)
    select
      t.user_id,
      'order',
      '입금 마감이 다가오고 있어요',
      format(
        '주문 %s의 입금이 아직 확인되지 않았어요. %s까지 입금되지 않으면 주문이 자동 취소됩니다.',
        t.order_number,
        to_char((t.created_at + interval '24 hours') at time zone 'Asia/Seoul', 'MM/DD HH24:MI')
      ),
      '/order/complete/' || t.id,
      'order',
      t.id
    from target t
    returning 1
  )
  update public.orders o
     set payment_reminder_sent_at = now()
    from target t
   where o.id = t.id;

  get diagnostics v_reminded_count = row_count;

  -- 2) 미결제 주문 자동 취소 + 쿠폰 복구
  --    · 무통장: 24시간 (입금 대기)
  --    · 카드(비무통장): 30분 — 선주문 생성 폐지(20260803) 후엔 "finalize 후 승인 전
  --      서버 크래시"로 남은 고아 pending의 백스톱 (정상 흐름에선 거의 발생 안 함)
  for v_order in
    select id, applied_member_coupon_id
      from public.orders
     where status = 'pending'
       and payment_status = 'pending'
       and (
         created_at < now() - interval '24 hours'
         or (
           coalesce(payment_method, 'bank_transfer') <> 'bank_transfer'
           and created_at < now() - interval '30 minutes'
         )
       )
  loop
    update public.orders
       set status = 'cancelled',
           payment_status = 'refunded',
           updated_at = now()
     where id = v_order.id;

    if v_order.applied_member_coupon_id is not null then
      update public.member_coupons
         set status = 'available',
             used_at = null,
             used_order_id = null,
             updated_at = now()
       where id = v_order.applied_member_coupon_id
         and status = 'used';

      get diagnostics v_iter_count = row_count;
      v_coupon_restored := v_coupon_restored + coalesce(v_iter_count, 0);
    end if;

    v_expired_count := v_expired_count + 1;
  end loop;

  -- 3) 오래된 카드 결제 세션 청소 (24시간) — 세션은 재고를 선점하지 않으므로 위생 목적
  delete from public.pg_checkout_sessions
   where created_at < now() - interval '24 hours';
  get diagnostics v_sessions_purged = row_count;

  return jsonb_build_object(
    'expired_count', v_expired_count,
    'coupons_restored', v_coupon_restored,
    'payment_reminders_sent', v_reminded_count,
    'checkout_sessions_purged', v_sessions_purged,
    'executed_at', now()
  );
end;
$$;

commit;

notify pgrst, 'reload schema';
