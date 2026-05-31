-- 정률(%) 쿠폰의 할인 상한(max_discount_amount) 누락 = 객단가 비례 무제한 손실 → 회사 파산 리스크.
-- 기존엔 프론트(AdminCouponsPage)에서만 검증해 service_role/SQL editor/타 RPC 경로로 우회 가능했다.
-- admin_create_coupon/admin_update_coupon에 서버 검증을 추가하고, DB CHECK로 최종 방어.
--
-- 비파괴: CREATE OR REPLACE FUNCTION + ADD CONSTRAINT ... NOT VALID(기존 행 미검증, 신규/수정만 강제).
-- DROP CONSTRAINT IF EXISTS는 같은 마이그레이션에서 동일 제약 재생성용(허용된 패턴).

begin;

-- 1) 생성 검증
create or replace function public.admin_create_coupon(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_title text;
  v_discount_type text;
  v_issuance_type text;
  v_code text;
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

  insert into public.coupons (
    title,
    description,
    discount_type,
    discount_value,
    max_discount_amount,
    min_order_amount,
    valid_from,
    valid_until,
    usage_limit_per_user,
    total_quantity,
    issuance_type,
    code,
    is_active,
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
    nullif(p_payload->>'valid_until', '')::timestamptz,
    nullif(p_payload->>'usage_limit_per_user', '')::integer,
    nullif(p_payload->>'total_quantity', '')::integer,
    v_issuance_type,
    v_code,
    coalesce((p_payload->>'is_active')::boolean, true),
    auth.uid()
  )
  returning id into v_id;

  return jsonb_build_object('success', true, 'coupon_id', v_id);
exception
  when unique_violation then
    raise exception '이미 사용 중인 쿠폰 코드입니다.';
end;
$$;

-- 2) 수정 검증 (업데이트 후 최종 상태 기준 — type 전환으로 캡 없는 정률이 되는 것도 차단)
create or replace function public.admin_update_coupon(p_coupon_id bigint, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.coupons%rowtype;
  v_final_type text;
  v_final_max integer;
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
    usage_limit_per_user = case when p_payload ? 'usage_limit_per_user'
      then nullif(p_payload->>'usage_limit_per_user', '')::integer
      else usage_limit_per_user end,
    total_quantity = case when p_payload ? 'total_quantity'
      then nullif(p_payload->>'total_quantity', '')::integer
      else total_quantity end,
    issuance_type = coalesce(p_payload->>'issuance_type', issuance_type),
    code = case when p_payload ? 'code'
      then nullif(trim(p_payload->>'code'), '')
      else code end,
    is_active = coalesce((p_payload->>'is_active')::boolean, is_active)
  where id = p_coupon_id;

  return jsonb_build_object('success', true, 'coupon_id', p_coupon_id);
exception
  when unique_violation then
    raise exception '이미 사용 중인 쿠폰 코드입니다.';
end;
$$;

-- 3) DB 최종 방어 — 정률 쿠폰은 max_discount_amount 필수 (RPC 우회 경로 대비).
--    NOT VALID: 기존 행은 검증하지 않고 신규/수정 행만 강제(기존 캡없는 정률이 있어도 마이그레이션 실패 안 함).
alter table public.coupons
  drop constraint if exists coupons_percentage_requires_max;
alter table public.coupons
  add constraint coupons_percentage_requires_max
  check (discount_type <> 'percentage' or max_discount_amount is not null)
  not valid;

commit;
