-- 2026-11-17 일성월심 학습지(앱 패키지 상품)는 회원만 구매한다. 다른 교재의 비회원 구매는 그대로다.
--
-- 까닭: 일성월심 앱은 수북 계정으로 로그인하고, 산 교재를 그 계정에 열어 준다. 비회원 주문에는 계정이 없다.
--
-- 하는 일:
--   · _ilseong_app_assert_member_purchase(p_book_ids) — 담은 책 중에 앱 패키지 상품(ilseong_app_products)의 책이 있으면 거절.
--   · create_guest_order, create_guest_pg_checkout_session — 약관 확인 바로 뒤에 위 검사 한 줄을 넣는다.
--     나머지 본문은 20260803061500_guest_orders.sql과 글자까지 같다(그 뒤로 재정의된 적 없음).
--     create or replace라 실행 권한(anon만)은 그대로다.
-- 앱 패키지로 지정한 상품이 없으면 아무것도 달라지지 않는다.
-- 화면: public-web의 로그인 관문이 앱 패키지 상품에는 "비회원으로 주문하기"를 내지 않고, 주문 페이지도 로그인으로 보낸다.
-- 이미 받은 비회원 앱 패키지 주문이 있다면 조회(get_guest_order_app_codes)와 코드 발급은 그대로 된다.
-- 롤백: 두 함수를 20260803061500의 정의로 되돌린다(검사 한 줄 제거).

create or replace function public._ilseong_app_assert_member_purchase(p_book_ids bigint[])
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.books b
    join public.ilseong_app_products ap on ap.product_id = b.product_id
    where b.id = any(coalesce(p_book_ids, '{}'::bigint[]))
  ) then
    raise exception '일성월심 학습지는 회원만 구매할 수 있어요. 로그인 후 주문해 주세요.';
  end if;
end;
$$;

revoke all on function public._ilseong_app_assert_member_purchase(bigint[]) from public, anon, authenticated;

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

  -- 일성월심 학습지(앱 패키지)는 회원만 살 수 있다(2026-11-17)
  perform public._ilseong_app_assert_member_purchase(p_book_ids);

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

  -- 일성월심 학습지(앱 패키지)는 회원만 살 수 있다(2026-11-17)
  perform public._ilseong_app_assert_member_purchase(p_book_ids);

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
