-- 비회원(게스트) 주문 + 비회원 주문 조회 (2026-08-03)
--
-- 배경: 비회원도 주문할 수 있게 한다. 회원 주문과 동일한 orders/order_items를
--   사용하되 user_id를 NULL로 두는 방식 (별도 guest_orders 테이블 방식은
--   2026041301에서 폐기된 전례가 있어 재도입하지 않음).
--
-- 전제: 20260803052801(카드 선주문 폐지·체크아웃 세션)이 먼저 적용돼 있어야 한다.
--   create_order_core를 이 마이그레이션이 다시 재정의(게스트 분기 추가)한다.
--
-- 구성 (비파괴 — ALTER는 NOT NULL 해제와 컬럼 추가뿐):
--   1) orders.user_id / pg_checkout_sessions.user_id → nullable (게스트 = NULL)
--   2) orders.guest_terms_agreed_at 추가 — 게스트 약관 동의 시각.
--      회원은 trigger_assert_terms_agreed가 profiles 동의를 강제하지만 게스트는
--      auth.uid()가 없어 트리거를 통과하므로, RPC에서 동의를 받아 여기 기록한다.
--   3) generate_guest_order_number(): 게스트 전용 랜덤 주문번호 ORD-YYMM-G + 10자.
--      회원 주문번호(ORD-YYMM-순번)는 완전 순차라 열거 가능한데, 비회원 조회가
--      "주문번호+휴대폰" 2요소뿐이므로 게스트 주문번호에는 엔트로피가 필수.
--      회원 번호 체계는 회계/시트 연동이 의존하므로 건드리지 않는다.
--   4) create_order_core 재정의 — p_is_guest 추가 (기존 16인자 시그니처는 DROP 후
--      17인자로 재생성. 인자 default 때문에 overload 중복이 생기면 호출이 ambiguous
--      해지므로 반드시 기존 시그니처를 먼저 제거한다. 데이터 변경 없음).
--      게스트 분기: user_id NULL 필수·쿠폰 금지·차단회원 전화번호 대조·
--      서버카트 삭제 생략·guest_terms_agreed_at 기록·랜덤 주문번호.
--      회원 분기: 기존과 동일 (auth 필수·차단 가드·재정의 시 유지 필수).
--   5) finalize_pg_checkout_session 재정의 — 세션 user_id NULL이면 게스트로 실체화.
--   6) create_guest_order (anon): 무통장 게스트 주문. 약관 동의 필수 +
--      동일 전화번호 pending 5건 제한 (재고 선점 어뷰징 방어).
--   7) create_guest_pg_checkout_session (anon): 카드 게스트 결제 세션.
--      시간당 동일 전화번호 10건 제한.
--   8) get_guest_order (anon): 주문번호+휴대폰으로 게스트 주문 조회.
--      IP당 15분 실패 20회 레이트리밋 (guest_order_lookup_attempts).
--   9) notify_gsheet_order_paid: '회원 여부'를 user_id 기준으로 (기존 '회원' 하드코딩).
--  10) list_admin_orders: 게스트 주문 검색(수령인 전화) + is_guest 필드.
--
-- 게스트 주문에 대해 의도적으로 "안 하는 것" (v1 정책):
--   - 셀프 취소/환불신청/구매확정 없음 — 자동취소(24h)·자동확정(D+7)·고객센터로 커버
--   - 쿠폰·적립·인앱알림·입금 리마인더 없음 (알림톡은 기존 경로가 배송정보 기반이라 동작)
--   - 게스트 장바구니 없음 — 바로구매 전용

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) user_id nullable화 (게스트 = NULL). FK/CASCADE는 그대로 — NULL 행은 무관.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders alter column user_id drop not null;
alter table public.pg_checkout_sessions alter column user_id drop not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 게스트 약관 동의 시각
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders add column if not exists guest_terms_agreed_at timestamptz;

comment on column public.orders.guest_terms_agreed_at is
  '비회원 주문의 약관·개인정보 동의 시각 (회원 주문은 NULL — profiles 동의로 갈음)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 게스트 주문번호 — ORD-YYMM-G + 대문자 hex 10자 (40bit 엔트로피)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.generate_guest_order_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_candidate text;
  v_tries integer := 0;
begin
  loop
    v_candidate := 'ORD-' || to_char(now(), 'YYMM') || '-G' ||
      upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text), 1, 10));
    exit when not exists (
      select 1 from public.orders where order_number = v_candidate
    ) and not exists (
      select 1 from public.pg_checkout_sessions where order_number = v_candidate
    );
    v_tries := v_tries + 1;
    if v_tries >= 5 then
      raise exception '주문번호 생성에 실패했습니다. 다시 시도해 주세요.';
    end if;
  end loop;
  return v_candidate;
end;
$$;

revoke all on function public.generate_guest_order_number() from public;
revoke all on function public.generate_guest_order_number() from anon;
revoke all on function public.generate_guest_order_number() from authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) create_order_core 재정의 — p_is_guest 추가
--    ⚠ default 인자 추가는 CREATE OR REPLACE로 안 되고 overload가 생기므로
--      기존 16인자 시그니처를 먼저 DROP (같은 트랜잭션에서 즉시 재생성).
--      create_order/create_pg_checkout_session 래퍼는 이름 기반 late binding이라
--      재정의 불필요 (새 17인자에 default로 결합).
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean
);

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
  p_validate_only boolean default false,
  p_is_guest boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_blocked boolean;
  v_phone_digits text;
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

  if p_is_guest then
    -- 게스트 경로: user_id 없이 진행. 호출자는 게스트 전용 RPC(아래 6·7)뿐.
    if v_user_id is not null then
      raise exception 'Guest order must not carry a user id';
    end if;
    if p_member_coupon_id is not null then
      raise exception '비회원 주문에는 쿠폰을 사용할 수 없습니다.';
    end if;
    if nullif(btrim(coalesce(p_shipping_recipient_name, '')), '') is null then
      raise exception '주문자 이름을 입력해 주세요.';
    end if;
    v_phone_digits := regexp_replace(coalesce(p_shipping_recipient_phone, ''), '\D', '', 'g');
    if length(v_phone_digits) < 9 or length(v_phone_digits) > 11 then
      raise exception '휴대폰 번호를 정확히 입력해 주세요.';
    end if;

    -- 차단 회원의 게스트 우회 방어 (전화번호 대조 — best effort).
    -- 사유를 드러내지 않는 일반 메시지로 응답한다.
    select exists (
      select 1
      from public.member_profiles mp
      where coalesce(mp.is_blocked, false)
        and nullif(regexp_replace(coalesce(mp.phone, ''), '\D', '', 'g'), '') = v_phone_digits
    ) into v_blocked;
    if coalesce(v_blocked, false) then
      raise exception '주문을 진행할 수 없습니다. 고객센터로 문의해 주세요.';
    end if;
  else
    -- 회원 경로: 기존 동작 그대로 (재정의 시에도 유지 필수)
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

  v_order_number := coalesce(
    nullif(btrim(coalesce(p_order_number, '')), ''),
    case when p_is_guest
      then public.generate_guest_order_number()
      else public.generate_order_number()
    end
  );

  insert into public.orders (
    user_id, order_number, status,
    shipping_recipient_name, shipping_recipient_phone,
    shipping_postal_code, shipping_address_line1, shipping_address_line2, shipping_memo,
    payment_method, payment_status,
    subtotal, shipping_fee, discount_amount, total_amount, item_count,
    auto_confirm_at,
    applied_member_coupon_id, coupon_discount_amount,
    refund_bank_name, refund_account_number, refund_account_holder,
    guest_terms_agreed_at
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
    nullif(btrim(coalesce(p_refund_account_holder, '')), ''),
    case when p_is_guest then now() else null end
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

  -- 서버 카트 정리는 회원 전용 (게스트는 서버 카트가 없음)
  if not p_is_guest then
    delete from public.cart_items
    where user_id = v_user_id and book_id = any(p_book_ids);
  end if;

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
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean
) from public;
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean
) from anon;
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean
) from authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) finalize_pg_checkout_session — 게스트 세션(user_id NULL)도 실체화
--    (20260803052801 본문과 동일, create_order_core 호출에 p_is_guest만 추가)
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
  -- 게스트 세션(user_id NULL)은 게스트 주문으로 실체화된다.
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
    p_validate_only => false,
    p_is_guest => (v_session.user_id is null)
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
-- 6) create_guest_order — 무통장 게스트 주문 (anon)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_guest_order(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_refund_bank text default null,
  p_refund_account_number text default null,
  p_refund_account_holder text default null,
  p_agree_terms boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone_digits text;
  v_pending_count integer;
begin
  -- 전자상거래 약관·개인정보 동의 — 게스트는 트리거 강제가 없으므로 RPC에서 요구
  if not coalesce(p_agree_terms, false) then
    raise exception '주문 진행을 위해 약관 및 개인정보 수집 동의가 필요합니다.';
  end if;

  -- 어뷰징 방어: 같은 번호로 미결제(pending) 게스트 주문 5건 제한.
  -- 무통장 게스트 주문은 재고를 선점하므로(24시간 자동취소 전까지) 상한이 필요하다.
  v_phone_digits := regexp_replace(coalesce(p_shipping_recipient_phone, ''), '\D', '', 'g');
  select count(*) into v_pending_count
  from public.orders o
  where o.user_id is null
    and o.status = 'pending'
    and regexp_replace(coalesce(o.shipping_recipient_phone, ''), '\D', '', 'g') = v_phone_digits;
  if v_pending_count >= 5 then
    raise exception '입금 대기 중인 주문이 많아 새 주문을 받을 수 없습니다. 기존 주문 입금 또는 자동취소 후 다시 시도해 주세요.';
  end if;

  return public.create_order_core(
    null,
    p_book_ids,
    p_quantities,
    p_shipping_recipient_name,
    p_shipping_recipient_phone,
    p_shipping_postal_code,
    p_shipping_address_line1,
    p_shipping_address_line2,
    p_shipping_memo,
    'bank_transfer',
    null,
    p_refund_bank,
    p_refund_account_number,
    p_refund_account_holder,
    p_order_number => null,
    p_validate_only => false,
    p_is_guest => true
  );
end;
$function$;

revoke all on function public.create_guest_order(
  bigint[], integer[], text, text, text, text, text, text, text, text, text, boolean
) from public;
revoke all on function public.create_guest_order(
  bigint[], integer[], text, text, text, text, text, text, text, text, text, boolean
) from authenticated;
grant execute on function public.create_guest_order(
  bigint[], integer[], text, text, text, text, text, text, text, text, text, boolean
) to anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) create_guest_pg_checkout_session — 카드 게스트 결제 세션 (anon)
--    세션은 재고를 선점하지 않으므로 시간당 생성 상한만 둔다.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_guest_pg_checkout_session(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_agree_terms boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone_digits text;
  v_recent_count integer;
  v_quote jsonb;
  v_order_number text;
begin
  if not coalesce(p_agree_terms, false) then
    raise exception '주문 진행을 위해 약관 및 개인정보 수집 동의가 필요합니다.';
  end if;

  v_phone_digits := regexp_replace(coalesce(p_shipping_recipient_phone, ''), '\D', '', 'g');
  select count(*) into v_recent_count
  from public.pg_checkout_sessions s
  where s.user_id is null
    and s.created_at > now() - interval '1 hour'
    and regexp_replace(coalesce(s.payload->>'shipping_recipient_phone', ''), '\D', '', 'g') = v_phone_digits;
  if v_recent_count >= 10 then
    raise exception '결제 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.';
  end if;

  -- create_order와 동일한 검증·금액 계산 (쓰기 없음)
  v_quote := public.create_order_core(
    null,
    p_book_ids,
    p_quantities,
    p_shipping_recipient_name,
    p_shipping_recipient_phone,
    p_shipping_postal_code,
    p_shipping_address_line1,
    p_shipping_address_line2,
    p_shipping_memo,
    'card',
    null,
    null,
    null,
    null,
    p_order_number => null,
    p_validate_only => true,
    p_is_guest => true
  );

  v_order_number := public.generate_guest_order_number();

  insert into public.pg_checkout_sessions (order_number, user_id, payload, expected_amount)
  values (
    v_order_number,
    null,
    jsonb_build_object(
      'book_ids', to_jsonb(p_book_ids),
      'quantities', to_jsonb(p_quantities),
      'shipping_recipient_name', p_shipping_recipient_name,
      'shipping_recipient_phone', p_shipping_recipient_phone,
      'shipping_postal_code', p_shipping_postal_code,
      'shipping_address_line1', p_shipping_address_line1,
      'shipping_address_line2', p_shipping_address_line2,
      'shipping_memo', p_shipping_memo,
      'payment_method', 'card',
      'member_coupon_id', null,
      'refund_bank', null,
      'refund_account_number', null,
      'refund_account_holder', null
    ),
    coalesce((v_quote->>'total_amount')::integer, 0)
  );

  return v_quote || jsonb_build_object(
    'order_number', v_order_number,
    'checkout_session', true
  );
end;
$function$;

revoke all on function public.create_guest_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, boolean
) from public;
revoke all on function public.create_guest_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, boolean
) from authenticated;
grant execute on function public.create_guest_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, boolean
) to anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8) get_guest_order — 주문번호 + 휴대폰 조회 (anon)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.guest_order_lookup_attempts (
  id bigint generated always as identity primary key,
  bucket_key text not null,
  attempted_at timestamptz not null default now()
);

create index if not exists idx_guest_lookup_attempts_bucket
  on public.guest_order_lookup_attempts (bucket_key, attempted_at desc);

-- 정책 없음 = 직접 접근 전면 차단 (definer RPC 내부 전용)
alter table public.guest_order_lookup_attempts enable row level security;

create or replace function public.get_guest_order(
  p_order_number text,
  p_phone text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ip text;
  v_fail_count integer;
  v_order_number text;
  v_phone_digits text;
  v_order record;
  v_items jsonb;
begin
  -- 호출자 IP (Supabase가 전달하는 요청 헤더) — 실패 시도 레이트리밋 키
  begin
    v_ip := split_part(coalesce(
      current_setting('request.headers', true)::jsonb->>'x-forwarded-for', ''
    ), ',', 1);
  exception when others then
    v_ip := '';
  end;
  if v_ip is null or btrim(v_ip) = '' then
    v_ip := 'noip';
  end if;

  -- 15분 내 실패 20회 초과 → 차단 (순차 주문번호 열거·전화번호 브루트포스 방어)
  select count(*) into v_fail_count
  from public.guest_order_lookup_attempts a
  where a.bucket_key = v_ip
    and a.attempted_at > now() - interval '15 minutes';
  if v_fail_count >= 20 then
    raise exception '조회 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.';
  end if;

  v_order_number := upper(btrim(coalesce(p_order_number, '')));
  v_phone_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');

  select o.* into v_order
  from public.orders o
  where o.user_id is null
    and upper(o.order_number) = v_order_number
    and regexp_replace(coalesce(o.shipping_recipient_phone, ''), '\D', '', 'g') = v_phone_digits
    and length(v_phone_digits) >= 9;

  if not found then
    -- 실패 기록 + 오래된 기록 정리 (테이블 비대화 방지)
    insert into public.guest_order_lookup_attempts (bucket_key) values (v_ip);
    delete from public.guest_order_lookup_attempts
    where attempted_at < now() - interval '1 day';
    return jsonb_build_object('found', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'title', oi.title,
    'option_label', oi.option_label,
    'condition_grade', oi.condition_grade,
    'cover_image_url', oi.cover_image_url,
    'quantity', oi.quantity,
    'unit_price', oi.unit_price,
    'total_price', oi.total_price,
    'refunded_at', oi.refunded_at,
    'refund_amount', oi.refund_amount
  ) order by oi.id), '[]'::jsonb)
  into v_items
  from public.order_items oi
  where oi.order_id = v_order.id;

  return jsonb_build_object(
    'found', true,
    'order', jsonb_build_object(
      'order_number', v_order.order_number,
      'status', v_order.status,
      'payment_status', v_order.payment_status,
      'payment_method', v_order.payment_method,
      'subtotal', v_order.subtotal,
      'shipping_fee', v_order.shipping_fee,
      'total_amount', v_order.total_amount,
      'refunded_amount', v_order.refunded_amount,
      'item_count', v_order.item_count,
      'created_at', v_order.created_at,
      'paid_at', v_order.paid_at,
      'confirmed_at', v_order.confirmed_at,
      'tracking_number', v_order.tracking_number,
      'tracking_carrier', v_order.tracking_carrier,
      'shipping_recipient_name', v_order.shipping_recipient_name,
      'shipping_recipient_phone', v_order.shipping_recipient_phone,
      'shipping_postal_code', v_order.shipping_postal_code,
      'shipping_address_line1', v_order.shipping_address_line1,
      'shipping_address_line2', v_order.shipping_address_line2,
      'shipping_memo', v_order.shipping_memo,
      'refund_bank_name', v_order.refund_bank_name,
      'refund_account_number', v_order.refund_account_number,
      'refund_account_holder', v_order.refund_account_holder,
      'refund_requested_at', v_order.refund_requested_at,
      'refunded_at', v_order.refunded_at
    ),
    'items', v_items
  );
end;
$function$;

revoke all on function public.get_guest_order(text, text) from public;
grant execute on function public.get_guest_order(text, text) to anon;
grant execute on function public.get_guest_order(text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9) notify_gsheet_order_paid — '회원 여부' 실값 반영 (기존 '회원' 하드코딩 수정)
--    (prod 현행 본문과 동일, 해당 라인만 변경)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_gsheet_order_paid()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_url text;
  v_token text;
  v_rows jsonb;
  v_pay text;
  v_paid_at text;
  v_buyer record;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token
  from vault.decrypted_secrets where name = 'gsheet_sync_token' limit 1;
  if v_url is null or btrim(v_url) = '' or v_token is null then
    return new;
  end if;

  v_pay := case new.payment_method
    when 'bank_transfer' then '무통장 입금'
    when 'card' then '카드(토스)'
    when 'toss_pay' then '토스페이'
    when 'kakao_pay' then '카카오페이'
    when 'naver_pay' then '네이버페이'
    else coalesce(new.payment_method, '-')
  end;
  v_paid_at := to_char(
    coalesce(new.paid_at, new.pg_approved_at, now()) at time zone 'Asia/Seoul',
    'YYYY-MM-DD HH24:MI:SS'
  );

  select p.name, p.email, p.phone into v_buyer
  from public.member_profiles p
  where p.user_id = new.user_id;

  select jsonb_agg(jsonb_build_object(
    '주문 번호', new.order_number,
    '주문 상태', '처리 중',
    '주문 일시', to_char(new.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI:SS'),
    '판매 채널', '수북 웹',
    '상품 이름', oi.title,
    '상품 옵션 정보', coalesce(oi.option_label, ''),
    '단일 정가', b.original_price,
    '단일 판매가', oi.unit_price,
    '구매 수량', oi.quantity,
    '상품 총액', oi.total_price,
    '배송 방식 이름', '일반택배',
    '배송비', coalesce(new.shipping_fee, 0),
    '상품 합계 금액', coalesce(new.subtotal, 0),
    '주문 할인 합계 금액', coalesce(new.discount_amount, 0) + coalesce(new.coupon_discount_amount, 0),
    '주문 금액', coalesce(new.total_amount, 0),
    '결제 상태', '결제 완료',
    '결제 완료 금액', coalesce(new.total_amount, 0),
    '결제1 - 결제 수단', v_pay,
    '결제1 - 결제 금액', coalesce(new.total_amount, 0),
    '결제1 - 결제 일시', v_paid_at,
    '회원 여부', case when new.user_id is null then '비회원' else '회원' end,
    '주문자명', coalesce(v_buyer.name, new.shipping_recipient_name, ''),
    '주문자 이메일', coalesce(v_buyer.email, ''),
    '주문자 핸드폰 번호', coalesce(v_buyer.phone, new.shipping_recipient_phone, ''),
    '수령인 이름', coalesce(new.shipping_recipient_name, ''),
    '수령인 핸드폰 번호', coalesce(new.shipping_recipient_phone, ''),
    '우편번호', coalesce(new.shipping_postal_code, ''),
    '주소', btrim(coalesce(new.shipping_address_line1, '') || ' ' || coalesce(new.shipping_address_line2, '')),
    '상품 위치', concat_ws(' / ', nullif(b.location, ''), b.serial_number::text)
  ) order by oi.id)
  into v_rows
  from public.order_items oi
  left join public.books b on b.id = oi.book_id
  where oi.order_id = new.id;

  if v_rows is null then
    return new;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('token', v_token, 'kind', 'sale', 'rows', v_rows),
    timeout_milliseconds := 25000
  );
  return new;
exception when others then
  return new;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10) list_admin_orders — 게스트 주문 검색(수령인 전화) + is_guest 필드
--     (prod 현행 본문과 동일, 검색 조건·is_guest만 추가)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_admin_orders(
  p_search text default null::text,
  p_statuses text[] default null::text[],
  p_from_date date default null::date,
  p_to_date date default null::date,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
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
        o.shipping_recipient_name ilike '%' || p_search || '%' or
        o.shipping_recipient_phone ilike '%' || p_search || '%')
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
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11) 주문 페이지 가격 재검증 RPC — 게스트(anon)도 호출 가능하게
--     (books/products는 공개 판매 정보라 노출 위험 없음. 기존 authenticated grant 유지)
-- ─────────────────────────────────────────────────────────────────────────────
grant execute on function public.get_books_pricing_for_order(bigint[]) to anon;

commit;

notify pgrst, 'reload schema';
