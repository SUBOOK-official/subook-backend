-- plpgsql 하이진 정리: 미사용 변수/죽은 대입 제거 (2026-08-04 plpgsql_check 전수 감사 후속)
--
-- 원칙: 각 함수는 프로덕션 현행 정의(pg_get_functiondef)를 그대로 덤프한 뒤
--   죽은 코드만 최소 제거. 로직·시그니처·옵션 변경 없음.
--   (FOR 정수 루프는 루프 변수를 자체 선언하므로 외부 declare는 완전 미사용이었음)
--
-- 변경 내역:
--   extract_chosung                   : 미사용 i 선언 제거
--   subscribe_restock                 : v_id 선언 + returning id into v_id 제거
--                                       (on conflict do nothing이라 항상 null이던 죽은 값)
--   admin_delete_coupon               : v_coupon 선언 제거, select * into → perform 1
--                                       (행 잠금 FOR UPDATE + FOUND 의미는 동일하게 보존)
--   submit_pickup_request             : v_item_count 선언 + 죽은 대입 제거 (개별등록 폐지 잔재)
--   create_order_core                 : 미사용 v_idx 선언 제거
--   admin_register_customer_inventory : 미사용 v_i, v_j 선언 제거
--
-- add_to_cart의 미사용 p_quantity 파라미터는 프론트(cart.js)가 넘기는 API 계약이라
-- 의도적으로 유지 (본문에 "단일재고 모델: quantity는 항상 1" 주석 기존재).

CREATE OR REPLACE FUNCTION public.extract_chosung(p_text text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE PARALLEL SAFE
AS $function$
declare
  v_result text := '';
  v_char text;
  v_code integer;
  v_chosung_array text[] := array[
    'ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ',
    'ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'
  ];
begin
  if p_text is null then return ''; end if;

  for i in 1..length(p_text) loop
    v_char := substring(p_text from i for 1);
    v_code := ascii(v_char);
    if v_code >= 44032 and v_code <= 55203 then
      v_result := v_result || v_chosung_array[((v_code - 44032) / 588) + 1];
    else
      v_result := v_result || lower(v_char);
    end if;
  end loop;

  return v_result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.subscribe_restock(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  -- product 존재 확인
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  insert into public.restock_notifications (user_id, product_id)
  values (v_user_id, p_product_id)
  on conflict (user_id, product_id) where notified_at is null
  do nothing;

  return jsonb_build_object('success', true, 'product_id', p_product_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_delete_coupon(p_coupon_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_used_count integer;
  v_reclaimed integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 존재 확인 + 행 잠금 (레코드 값 자체는 쓰지 않음)
  perform 1 from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;

  select count(*) into v_used_count
  from public.member_coupons
  where coupon_id = p_coupon_id and status = 'used';

  if v_used_count > 0 then
    raise exception '사용 이력이 있는 쿠폰(%건)은 삭제할 수 없습니다. 대신 비활성화하세요.', v_used_count;
  end if;

  -- 미사용 발급분 회수 (회원 쿠폰함에서 사라짐)
  delete from public.member_coupons where coupon_id = p_coupon_id;
  get diagnostics v_reclaimed = row_count;

  delete from public.coupons where id = p_coupon_id;

  return jsonb_build_object(
    'success', true,
    'coupon_id', p_coupon_id,
    'reclaimed_count', v_reclaimed
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.submit_pickup_request(p_pickup_recipient_name text, p_pickup_recipient_phone text, p_pickup_postal_code text, p_pickup_address_line1 text, p_pickup_address_line2 text, p_pickup_memo text, p_settlement_bank_name text, p_settlement_account_number text, p_settlement_account_holder text, p_items jsonb, p_settlement_account_id bigint DEFAULT NULL::bigint, p_pickup_email text DEFAULT NULL::text, p_pickup_entrance_password text DEFAULT NULL::text, p_desired_pickup_date date DEFAULT NULL::date, p_expected_book_count integer DEFAULT NULL::integer, p_box_count integer DEFAULT NULL::integer, p_policy_agreed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid;
  v_request_id bigint;
  v_request_number text;
  v_item jsonb;
  v_account record;
  v_bank_name text;
  v_account_holder text;
  v_account_digits text;
  v_account_ciphertext bytea;
  v_account_last4 text;
  v_pickup_email text;
  v_entrance_password text;
  v_expected_book_count integer;
  v_box_count integer;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  if not coalesce(p_policy_agreed, false) then
    raise exception '수거 신청은 이용약관 및 개인정보처리방침 동의가 필요합니다.';
  end if;

  -- 신규 모델: 사용자는 교재를 개별 등록하지 않는다(검수 때 운영팀이 등록).
  -- p_items는 비어 있는 게 정상이며, 0개여도 막지 않는다.

  if p_settlement_account_id is not null then
    select
      msa.bank_name,
      msa.account_holder,
      msa.account_number_ciphertext,
      coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number)) as account_last4,
      public.decrypt_account_number(msa.account_number_ciphertext) as decrypted_account_number,
      msa.account_number as legacy_account_number
    into v_account
    from public.member_settlement_accounts msa
    where msa.user_id = v_user_id
      and msa.id = p_settlement_account_id;

    if not found then
      raise exception 'Settlement account not found';
    end if;

    v_bank_name := v_account.bank_name;
    v_account_holder := v_account.account_holder;
    v_account_digits := coalesce(
      public.normalize_account_number(v_account.decrypted_account_number),
      public.normalize_account_number(v_account.legacy_account_number)
    );
    v_account_ciphertext := coalesce(
      v_account.account_number_ciphertext,
      public.encrypt_account_number(v_account_digits)
    );
    v_account_last4 := coalesce(v_account.account_last4, public.get_account_last4(v_account_digits));
  else
    v_bank_name := nullif(btrim(coalesce(p_settlement_bank_name, '')), '');
    v_account_holder := nullif(btrim(coalesce(p_settlement_account_holder, '')), '');
    v_account_digits := public.normalize_account_number(p_settlement_account_number);
    v_account_ciphertext := public.encrypt_account_number(v_account_digits);
    v_account_last4 := public.get_account_last4(v_account_digits);
  end if;

  if v_bank_name is null or v_account_holder is null or v_account_ciphertext is null then
    raise exception 'Settlement account information is required';
  end if;

  v_pickup_email := nullif(btrim(coalesce(p_pickup_email, '')), '');
  v_entrance_password := nullif(btrim(coalesce(p_pickup_entrance_password, '')), '');

  -- 예상 권수 / 박스 개수 필수화 (신규 모델의 핵심 입력값).
  v_expected_book_count := p_expected_book_count;
  v_box_count := p_box_count;
  if v_expected_book_count is null or v_expected_book_count <= 0 then
    raise exception '예상 권수를 입력해 주세요.';
  end if;
  if v_box_count is null or v_box_count <= 0 then
    raise exception '박스 개수를 입력해 주세요.';
  end if;

  v_request_number := public.generate_pickup_request_number();

  insert into public.pickup_requests (
    user_id, request_number, status,
    pickup_recipient_name, pickup_recipient_phone,
    pickup_postal_code, pickup_address_line1, pickup_address_line2, pickup_memo,
    pickup_email, pickup_entrance_password,
    desired_pickup_date, expected_book_count, box_count,
    settlement_bank_name, settlement_account_number, settlement_account_number_ciphertext,
    settlement_account_last4, settlement_account_holder,
    policy_agreed_at, item_count
  ) values (
    v_user_id, v_request_number, 'pending',
    p_pickup_recipient_name, p_pickup_recipient_phone,
    p_pickup_postal_code, p_pickup_address_line1, p_pickup_address_line2, p_pickup_memo,
    v_pickup_email, v_entrance_password,
    p_desired_pickup_date, v_expected_book_count, v_box_count,
    v_bank_name, public.mask_account_number(v_account_last4), v_account_ciphertext,
    v_account_last4, v_account_holder,
    now(), v_expected_book_count
  )
  returning id into v_request_id;

  -- p_items가 비어 있으면 루프 0회(신규 모델 정상). 값이 오면 호환 위해 그대로 저장.
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    insert into public.pickup_items (
      pickup_request_id,
      book_id,
      title, subject, brand, book_type,
      published_year, instructor_name, original_price,
      condition_memo, is_manual_entry
    ) values (
      v_request_id,
      case when (v_item->>'book_id') is not null and (v_item->>'book_id') <> ''
        then (v_item->>'book_id')::bigint else null end,
      v_item->>'title',
      nullif(btrim(v_item->>'subject'), ''),
      nullif(btrim(v_item->>'brand'), ''),
      nullif(btrim(v_item->>'book_type'), ''),
      case when (v_item->>'published_year') is not null and (v_item->>'published_year') <> ''
        then (v_item->>'published_year')::integer else null end,
      nullif(btrim(v_item->>'instructor_name'), ''),
      case when (v_item->>'original_price') is not null and (v_item->>'original_price') <> ''
        then (v_item->>'original_price')::integer else null end,
      nullif(btrim(v_item->>'condition_memo'), ''),
      coalesce((v_item->>'is_manual_entry')::boolean, false)
    );
  end loop;

  return jsonb_build_object(
    'request_id', v_request_id,
    'request_number', v_request_number,
    'item_count', v_expected_book_count,
    'expected_book_count', v_expected_book_count,
    'box_count', v_box_count,
    'settlement_account_last4', v_account_last4
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_order_core(p_user_id uuid, p_book_ids bigint[], p_quantities integer[], p_shipping_recipient_name text, p_shipping_recipient_phone text, p_shipping_postal_code text, p_shipping_address_line1 text, p_shipping_address_line2 text, p_shipping_memo text, p_payment_method text DEFAULT 'bank_transfer'::text, p_member_coupon_id bigint DEFAULT NULL::bigint, p_refund_bank text DEFAULT NULL::text, p_refund_account_number text DEFAULT NULL::text, p_refund_account_holder text DEFAULT NULL::text, p_order_number text DEFAULT NULL::text, p_validate_only boolean DEFAULT false, p_is_guest boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.admin_register_customer_inventory(p_shipment_id bigint, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item jsonb;
  v_opt jsonb;
  v_meta record;
  v_prod record;
  v_group_key text;
  v_product_id bigint;
  v_existing_id bigint;
  v_title text;
  v_original integer;
  v_dtype text;
  v_dvalue integer;
  v_price integer;
  v_cover text;
  v_details text[];
  v_is_public boolean;
  v_qty integer;
  v_row_qty integer;
  v_optname text;
  v_rep_original integer;
  v_options text[];
  v_subject text;
  v_brand text;
  v_btype text;
  v_location text;
  v_serial integer;
  v_serial_start integer;
  v_override integer;
  v_item_books integer;
  v_seq_books integer := 0;
  v_created_serials integer[] := '{}'::integer[];
  v_created_products integer := 0;
  v_created_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from public.shipments where id = p_shipment_id) then
    raise exception '고객(수거) 정보를 찾을 수 없습니다.';
  end if;

  -- 시작 일련번호 (2026-07-20): 지정 시 등록 순서대로 start, start+1, ... 순차 배정
  v_serial_start := nullif(btrim(coalesce(p_payload->>'serial_start', '')), '')::integer;
  if v_serial_start is not null and v_serial_start < 1 then
    raise exception '시작 일련번호는 1 이상의 숫자여야 합니다.';
  end if;

  -- ── 신규 교재 ──────────────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'new_products', '[]'::jsonb))
  loop
    v_title := nullif(btrim(v_item->>'title'), '');
    if v_title is null then
      continue;
    end if;

    v_original := nullif(btrim(coalesce(v_item->>'original_price', '')), '')::integer;
    v_dtype := coalesce(nullif(v_item->>'discount_type', ''), 'none');
    v_dvalue := nullif(btrim(coalesce(v_item->>'discount_value', '')), '')::integer;
    v_price := public._register_compute_price(v_original, v_dtype, v_dvalue);
    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;
    v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;
    -- 창고 위치 (2026-07-18: NFKC 정규화 — 전각/반각 통일)
    v_location := nullif(normalize(btrim(coalesce(v_item->>'location', '')), nfkc), '');

    -- 행 수량 (2026-07-22): 같은 구성(옵션 세트)을 수량만큼 반복 생성. 기본 1, 1~999.
    v_row_qty := least(greatest(coalesce(nullif(btrim(coalesce(v_item->>'quantity', '')), '')::integer, 1), 1), 999);
    -- 행별 일련번호 직접 지정 (2026-07-22)
    v_override := nullif(btrim(coalesce(v_item->>'serial_override', '')), '')::integer;
    if v_override is not null and v_override < 1 then
      raise exception '행별 일련번호는 1 이상의 숫자여야 합니다.';
    end if;
    v_item_books := 0;

    select * into v_meta from public._register_infer_product_meta(v_title);
    -- 명시 카테고리가 오면 제목 파싱보다 우선 (빈 값이면 파싱 폴백 — 2026-07-13)
    v_subject := coalesce(nullif(btrim(coalesce(v_item->>'subject', '')), ''), v_meta.subject);
    v_brand   := coalesce(nullif(btrim(coalesce(v_item->>'brand', '')), ''), v_meta.brand);
    v_btype   := coalesce(nullif(btrim(coalesce(v_item->>'book_type', '')), ''), v_meta.book_type);
    v_group_key := public.storefront_product_group_key(
      v_title, null, v_subject, v_brand, v_btype, v_meta.year, v_meta.instructor
    );

    select id into v_existing_id from public.products where group_key = v_group_key;
    if v_existing_id is null then
      insert into public.products (
        group_key, title, option, subject, brand, book_type,
        published_year, instructor_name, cover_image_url, status
      ) values (
        v_group_key, v_title, null, v_subject, v_brand, v_btype,
        v_meta.year, v_meta.instructor, v_cover, 'selling'
      ) returning id into v_product_id;
      v_created_products := v_created_products + 1;
    else
      v_product_id := v_existing_id;
      if v_cover is not null then
        update public.products
        set cover_image_url = coalesce(cover_image_url, v_cover), updated_at = now()
        where id = v_product_id;
      end if;
    end if;

    v_options := array(
      select btrim(x) from regexp_split_to_table(coalesce(v_item->>'option', ''), ',') x
      where btrim(x) <> ''
    );
    if array_length(v_options, 1) is null then
      v_options := array[null]::text[];
    end if;

    foreach v_optname in array v_options
    loop
      for v_j in 1..v_row_qty
      loop
        -- 일련번호 배정: 행 지정 > 시작 번호 순차 > 시퀀스 자동
        if v_override is not null then
          v_serial := v_override + v_item_books;
        elsif v_serial_start is not null then
          v_serial := v_serial_start + v_seq_books;
        else
          v_serial := public._next_book_serial();
        end if;
        if v_serial = any(v_created_serials) then
          raise exception '일련번호 %가 이번 등록에서 두 번 배정됩니다. 행별 지정 번호가 겹치지 않는지 확인해 주세요.', v_serial;
        end if;
        if exists (select 1 from public.books where serial_number = v_serial) then
          raise exception '일련번호 %가 이미 사용 중입니다. 다른 번호를 입력해 주세요.', v_serial;
        end if;
        insert into public.books (
          shipment_id, title, option, product_id, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at, serial_number, location
        ) values (
          p_shipment_id, v_title, nullif(v_optname, ''), v_product_id, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now(), v_serial, v_location
        );
        if v_override is null and v_serial_start is not null then
          v_seq_books := v_seq_books + 1;
        end if;
        v_item_books := v_item_books + 1;
        v_created_books := v_created_books + 1;
        v_created_serials := v_created_serials || v_serial;
      end loop;
    end loop;
  end loop;

  -- ── 기존 교재 재고 추가 ────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'existing_additions', '[]'::jsonb))
  loop
    v_product_id := nullif(btrim(coalesce(v_item->>'product_id', '')), '')::bigint;
    if v_product_id is null then
      continue;
    end if;

    select * into v_prod from public.products where id = v_product_id;
    if not found then
      continue;
    end if;

    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;
    -- 창고 위치 (2026-07-18)
    v_location := nullif(normalize(btrim(coalesce(v_item->>'location', '')), nfkc), '');
    -- 행별 일련번호 직접 지정 (2026-07-22) — 항목(교재) 단위, 항목 내 순서대로 +1
    v_override := nullif(btrim(coalesce(v_item->>'serial_override', '')), '')::integer;
    if v_override is not null and v_override < 1 then
      raise exception '행별 일련번호는 1 이상의 숫자여야 합니다.';
    end if;
    v_item_books := 0;

    select max(original_price) into v_rep_original
    from public.books where product_id = v_product_id and status = 'on_sale';

    if v_cover is not null and v_prod.cover_image_url is null then
      update public.products set cover_image_url = v_cover, updated_at = now() where id = v_product_id;
    end if;

    for v_opt in
      select value from jsonb_array_elements(coalesce(v_item->'options', '[]'::jsonb))
    loop
      v_qty := coalesce(nullif(btrim(coalesce(v_opt->>'quantity', '')), '')::integer, 0);
      if v_qty < 1 then
        continue;
      end if;
      v_optname := nullif(btrim(coalesce(v_opt->>'option', '')), '');
      v_price := nullif(btrim(coalesce(v_opt->>'price', '')), '')::integer;
      v_original := coalesce(nullif(btrim(coalesce(v_opt->>'original_price', '')), '')::integer, v_rep_original);
      v_dtype := coalesce(nullif(v_opt->>'discount_type', ''), 'none');
      v_dvalue := nullif(btrim(coalesce(v_opt->>'discount_value', '')), '')::integer;
      v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;

      for v_i in 1..v_qty
      loop
        -- 일련번호 배정: 행 지정 > 시작 번호 순차 > 시퀀스 자동
        if v_override is not null then
          v_serial := v_override + v_item_books;
        elsif v_serial_start is not null then
          v_serial := v_serial_start + v_seq_books;
        else
          v_serial := public._next_book_serial();
        end if;
        if v_serial = any(v_created_serials) then
          raise exception '일련번호 %가 이번 등록에서 두 번 배정됩니다. 행별 지정 번호가 겹치지 않는지 확인해 주세요.', v_serial;
        end if;
        if exists (select 1 from public.books where serial_number = v_serial) then
          raise exception '일련번호 %가 이미 사용 중입니다. 다른 번호를 입력해 주세요.', v_serial;
        end if;
        insert into public.books (
          shipment_id, title, option, product_id, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at, serial_number, location
        ) values (
          p_shipment_id, v_prod.title, v_optname, v_product_id, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now(), v_serial, v_location
        );
        if v_override is null and v_serial_start is not null then
          v_seq_books := v_seq_books + 1;
        end if;
        v_item_books := v_item_books + 1;
        v_created_books := v_created_books + 1;
        v_created_serials := v_created_serials || v_serial;
      end loop;
    end loop;
  end loop;

  -- 수동 시작 배정 시 시퀀스가 뒤처지지 않게 동기화 (자동 채번 exists 루프 비용 방지).
  -- 행별 지정 번호는 시퀀스에 반영하지 않는다 — 멀리 떨어진 번호로 시퀀스를 튀기면
  -- 번호 공간이 낭비되고, 자동 채번은 exists 루프가 충돌을 건너뛰므로 안전하다.
  if v_serial_start is not null and v_seq_books > 0 then
    perform setval('public.books_serial_number_seq',
      greatest(
        (select last_value from public.books_serial_number_seq),
        (v_serial_start + v_seq_books - 1)::bigint
      ));
  end if;

  return jsonb_build_object(
    'success', true,
    'created_products', v_created_products,
    'created_books', v_created_books,
    'created_serials', to_jsonb(v_created_serials)
  );
end;
$function$
;

