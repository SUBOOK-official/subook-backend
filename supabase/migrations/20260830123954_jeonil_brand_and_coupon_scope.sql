-- 전일학원 콜라보 준비: 브랜드 허용 + 쿠폰 브랜드 스코프 (2026-08-30)
--
-- 1) books/products brand_check에 '전일학원' 추가 — 없으면 상품 등록 자체가 불가.
--    (프론트 동기 3곳: admin productCategories.js / AdminProductMastersPage.jsx /
--     public publicStoreNavigation.js — 같은 커밋에서 반영)
-- 2) coupons.scope_brand — 특정 브랜드 교재 한정 쿠폰 (예: 전일학원 한정 3,000원).
--    · 검증/할인 기준 = 해당 브랜드 품목 소계(v_scope_subtotal):
--      스코프 품목이 없으면 사용 불가, min_order_amount·정액 상한·정률 계산 모두
--      스코프 소계 기준. free_shipping은 배송비 성격상 스코프 품목 존재만 확인.
--    · 반영 지점: create_order_core(주문 시 검증·계산) + get_applicable_coupons(주문서
--      쿠폰 목록 필터) + admin_create/update_coupon(설정 저장).
--
-- 함수 본문은 프로덕션 pg_get_functiondef 덤프(2026-08-30)를 베이스로 패치 —
-- 기존 가드(게스트 쿠폰 금지, 차단회원, validate_only, 환불계좌, 정률 상한,
-- 기간유형 정합성 등)는 전부 그대로 유지한다 (재정의 시 유지 필수 항목들).
--
-- 파괴적 변경 없음: 제약은 drop 후 즉시 확장 재생성, get_applicable_coupons는
-- 시그니처 확장(파라미터 추가)이라 오버로드 모호성 방지를 위해 drop 후 재생성.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 브랜드 허용 목록에 '전일학원' 추가 (2026050607 패턴)
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.books drop constraint if exists books_brand_check;
alter table public.books add constraint books_brand_check
  check (brand is null or brand in (
    '시대인재', '강남대성', '대성마이맥', '이투스', 'EBS',
    '메가스터디', '이감', '상상국어평가연구소',
    '전일학원',
    '기타'
  ));

alter table public.products drop constraint if exists products_brand_check;
alter table public.products add constraint products_brand_check
  check (
    nullif(btrim(coalesce(brand, '')), '') is not null
    and brand in (
      '시대인재', '강남대성', '대성마이맥', '이투스', 'EBS',
      '메가스터디', '이감', '상상국어평가연구소',
      '전일학원',
      '기타'
    )
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) coupons.scope_brand
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.coupons
  add column if not exists scope_brand text null;

comment on column public.coupons.scope_brand is
  '브랜드 한정 쿠폰 (books.brand 값과 일치). null=전체 주문 대상. 검증·할인은 해당 브랜드 품목 소계 기준.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) admin_create_coupon — scope_brand 저장 추가 (그 외 프로덕션 정의 그대로)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_create_coupon(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id bigint;
  v_title text;
  v_discount_type text;
  v_issuance_type text;
  v_code text;
  v_valid_days integer;
  v_valid_until timestamptz;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_title := nullif(trim(p_payload->>'title'), '');
  if v_title is null then
    raise exception '쿠폰 이름은 필수입니다.';
  end if;

  v_discount_type := p_payload->>'discount_type';
  if v_discount_type is null or v_discount_type not in ('fixed', 'percentage', 'free_shipping') then
    raise exception '할인 형식이 올바르지 않습니다.';
  end if;

  -- 정률 쿠폰은 할인 상한 필수 (객단가 비례 무제한 손실 방지).
  if v_discount_type = 'percentage'
     and coalesce(nullif(p_payload->>'max_discount_amount', '')::integer, 0) <= 0 then
    raise exception '정률(%%) 쿠폰은 할인 상한 금액을 0보다 크게 설정해야 합니다.';
  end if;

  v_issuance_type := p_payload->>'issuance_type';
  if v_issuance_type is null or v_issuance_type not in ('admin_assigned', 'code', 'download') then
    raise exception '발급 방식이 올바르지 않습니다.';
  end if;

  v_code := nullif(trim(p_payload->>'code'), '');
  if v_issuance_type = 'code' and v_code is null then
    raise exception '코드 입력형 쿠폰은 code 값이 필요합니다.';
  end if;

  v_valid_days := nullif(p_payload->>'valid_days', '')::integer;
  v_valid_until := nullif(p_payload->>'valid_until', '')::timestamptz;
  if v_valid_days is not null and v_valid_until is not null then
    raise exception '지급일 기준 사용 기간과 종료일은 동시에 설정할 수 없습니다.';
  end if;
  if v_valid_days is not null and v_valid_days <= 0 then
    raise exception '지급일 기준 사용 기간은 1일 이상이어야 합니다.';
  end if;

  insert into public.coupons (
    title,
    description,
    discount_type,
    discount_value,
    max_discount_amount,
    min_order_amount,
    valid_from,
    valid_until,
    valid_days,
    usage_limit_per_user,
    total_quantity,
    budget_cap_amount,
    issuance_type,
    code,
    issue_on_signup,
    is_active,
    scope_brand,
    created_by
  )
  values (
    v_title,
    nullif(trim(p_payload->>'description'), ''),
    v_discount_type,
    coalesce((p_payload->>'discount_value')::integer, 0),
    nullif(p_payload->>'max_discount_amount', '')::integer,
    coalesce((p_payload->>'min_order_amount')::integer, 0),
    nullif(p_payload->>'valid_from', '')::timestamptz,
    v_valid_until,
    v_valid_days,
    nullif(p_payload->>'usage_limit_per_user', '')::integer,
    nullif(p_payload->>'total_quantity', '')::integer,
    nullif(p_payload->>'budget_cap_amount', '')::integer,
    v_issuance_type,
    v_code,
    coalesce((p_payload->>'issue_on_signup')::boolean, false),
    coalesce((p_payload->>'is_active')::boolean, true),
    nullif(trim(p_payload->>'scope_brand'), ''),
    auth.uid()
  )
  returning id into v_id;

  return jsonb_build_object('success', true, 'coupon_id', v_id);
exception
  when unique_violation then
    raise exception '이미 사용 중인 쿠폰 코드입니다.';
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) admin_update_coupon — scope_brand 갱신 추가 (그 외 프로덕션 정의 그대로)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_coupon(p_coupon_id bigint, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_existing public.coupons%rowtype;
  v_final_type text;
  v_final_max integer;
  v_final_days integer;
  v_final_until timestamptz;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_existing from public.coupons where id = p_coupon_id;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;

  v_final_type := coalesce(p_payload->>'discount_type', v_existing.discount_type);
  v_final_max := case when p_payload ? 'max_discount_amount'
    then nullif(p_payload->>'max_discount_amount', '')::integer
    else v_existing.max_discount_amount end;
  if v_final_type = 'percentage' and coalesce(v_final_max, 0) <= 0 then
    raise exception '정률(%%) 쿠폰은 할인 상한 금액을 0보다 크게 설정해야 합니다.';
  end if;

  -- 기한 유형 정합성 (업데이트 후 최종 상태 기준)
  v_final_days := case when p_payload ? 'valid_days'
    then nullif(p_payload->>'valid_days', '')::integer
    else v_existing.valid_days end;
  v_final_until := case when p_payload ? 'valid_until'
    then nullif(p_payload->>'valid_until', '')::timestamptz
    else v_existing.valid_until end;
  if v_final_days is not null and v_final_until is not null then
    raise exception '지급일 기준 사용 기간과 종료일은 동시에 설정할 수 없습니다.';
  end if;
  if v_final_days is not null and v_final_days <= 0 then
    raise exception '지급일 기준 사용 기간은 1일 이상이어야 합니다.';
  end if;

  update public.coupons
  set
    title = coalesce(nullif(trim(p_payload->>'title'), ''), title),
    description = case when p_payload ? 'description'
      then nullif(trim(p_payload->>'description'), '')
      else description end,
    discount_type = coalesce(p_payload->>'discount_type', discount_type),
    discount_value = coalesce((p_payload->>'discount_value')::integer, discount_value),
    max_discount_amount = case when p_payload ? 'max_discount_amount'
      then nullif(p_payload->>'max_discount_amount', '')::integer
      else max_discount_amount end,
    min_order_amount = coalesce((p_payload->>'min_order_amount')::integer, min_order_amount),
    valid_from = case when p_payload ? 'valid_from'
      then nullif(p_payload->>'valid_from', '')::timestamptz
      else valid_from end,
    valid_until = case when p_payload ? 'valid_until'
      then nullif(p_payload->>'valid_until', '')::timestamptz
      else valid_until end,
    valid_days = case when p_payload ? 'valid_days'
      then nullif(p_payload->>'valid_days', '')::integer
      else valid_days end,
    usage_limit_per_user = case when p_payload ? 'usage_limit_per_user'
      then nullif(p_payload->>'usage_limit_per_user', '')::integer
      else usage_limit_per_user end,
    total_quantity = case when p_payload ? 'total_quantity'
      then nullif(p_payload->>'total_quantity', '')::integer
      else total_quantity end,
    budget_cap_amount = case when p_payload ? 'budget_cap_amount'
      then nullif(p_payload->>'budget_cap_amount', '')::integer
      else budget_cap_amount end,
    issuance_type = coalesce(p_payload->>'issuance_type', issuance_type),
    code = case when p_payload ? 'code'
      then nullif(trim(p_payload->>'code'), '')
      else code end,
    issue_on_signup = coalesce((p_payload->>'issue_on_signup')::boolean, issue_on_signup),
    is_active = coalesce((p_payload->>'is_active')::boolean, is_active),
    scope_brand = case when p_payload ? 'scope_brand'
      then nullif(trim(p_payload->>'scope_brand'), '')
      else scope_brand end
  where id = p_coupon_id;

  return jsonb_build_object('success', true, 'coupon_id', p_coupon_id);
exception
  when unique_violation then
    raise exception '이미 사용 중인 쿠폰 코드입니다.';
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) get_applicable_coupons — p_book_ids 추가 + 스코프 필터
--    시그니처 확장이라 구버전을 drop (남겨두면 1-인자 호출이 모호해짐)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.get_applicable_coupons(integer);

CREATE OR REPLACE FUNCTION public.get_applicable_coupons(p_subtotal integer DEFAULT 0, p_book_ids bigint[] DEFAULT NULL)
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
      'scope_brand', c.scope_brand,
      'expires_at', mc.expires_at,
      'issued_at', mc.issued_at
    ) as row_data
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    where mc.user_id = v_user_id
      and mc.status = 'available'
      and (mc.expires_at is null or mc.expires_at >= now())
      and c.is_active = true
      and (
        -- 브랜드 한정 쿠폰: 해당 브랜드 품목 소계 기준으로 최소금액 검증.
        -- p_book_ids 미전달(구 클라이언트)이면 스코프 쿠폰은 목록에서 제외 — 주문 시
        -- create_order_core가 어차피 거부하므로 보수적으로 숨긴다.
        case
          when c.scope_brand is null then c.min_order_amount <= p_subtotal
          else p_book_ids is not null
            and exists (
              select 1 from public.books b
              where b.id = any(p_book_ids) and b.brand = c.scope_brand
            )
            and c.min_order_amount <= (
              select coalesce(sum(b.price), 0) from public.books b
              where b.id = any(p_book_ids) and b.brand = c.scope_brand
            )
        end
      )
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
$function$;

grant execute on function public.get_applicable_coupons(integer, bigint[]) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) create_order_core — 스코프 검증·할인 반영 (그 외 프로덕션 정의 그대로:
--    게스트 분기, 차단 가드, 1권 제한, 예약 충돌, validate_only, 환불계좌,
--    무료배송 임계, 도서산간 가산, 쿠폰 사용 스탬프, 카트 정리 전부 유지)
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_scope_subtotal integer := 0;
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

    -- 브랜드 한정 쿠폰 (2026-08-30 전일학원): 해당 브랜드 품목 소계를 기준으로
    -- 사용 가능 여부·최소 주문 금액·할인액을 계산한다. 일반 쿠폰은 기존 그대로.
    if v_coupon.scope_brand is not null then
      select coalesce(sum(b.price), 0) into v_scope_subtotal
      from public.books b
      where b.id = any(p_book_ids) and b.brand = v_coupon.scope_brand;
      if v_scope_subtotal <= 0 then
        raise exception '이 쿠폰은 % 교재 주문에만 사용할 수 있습니다.', v_coupon.scope_brand;
      end if;
      if v_coupon.min_order_amount > v_scope_subtotal then
        raise exception '% 교재 %원 이상 주문 시 사용할 수 있는 쿠폰입니다.',
          v_coupon.scope_brand, v_coupon.min_order_amount;
      end if;
    else
      v_scope_subtotal := v_subtotal;
      if v_coupon.min_order_amount > v_subtotal then
        raise exception '최소 주문 금액(%원)을 만족하지 않습니다.', v_coupon.min_order_amount;
      end if;
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
      v_discount := least(v_coupon.discount_value, v_scope_subtotal);
    elsif v_coupon.discount_type = 'percentage' then
      v_discount := (v_scope_subtotal * v_coupon.discount_value) / 100;
      if v_coupon.max_discount_amount is not null then
        v_discount := least(v_discount, v_coupon.max_discount_amount);
      end if;
    elsif v_coupon.discount_type = 'free_shipping' then
      -- 스코프가 있어도 배송비는 주문 단위 — 스코프 품목 존재 검증만 위에서 수행
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

commit;
