-- 쿠폰 시스템 PR 1: 데이터 모델 + 어드민 CRUD
-- 어드민이 쿠폰 템플릿(할인 형식/조건/유효기간/발급 방식)을 자율 정의.
-- 발급(member_coupons)과 주문 적용은 PR 2/3에서 처리.

-- ── coupons: 쿠폰 정의 템플릿 ────────────────────────────────────────
create table if not exists public.coupons (
  id bigint generated always as identity primary key,
  title text not null,
  description text null,

  -- 할인 형식
  discount_type text not null
    check (discount_type in ('fixed', 'percentage', 'free_shipping')),
  discount_value integer not null default 0
    check (discount_value >= 0),
  -- percentage 쿠폰의 할인 상한 (예: 10%지만 최대 5,000원). null이면 상한 없음
  max_discount_amount integer null
    check (max_discount_amount is null or max_discount_amount >= 0),
  -- 최소 주문 금액
  min_order_amount integer not null default 0
    check (min_order_amount >= 0),

  -- 유효 기간 (template-level. member_coupons 발급 시 별도 expires_at 가능)
  valid_from timestamptz null,
  valid_until timestamptz null,

  -- 한도
  -- 1인당 사용 가능 횟수 (null = 무제한). 사용 시점에 검증 (PR 3).
  usage_limit_per_user integer null
    check (usage_limit_per_user is null or usage_limit_per_user > 0),
  -- 전체 발급 한도 (null = 무제한). 발급 시점에 검증 (PR 2).
  total_quantity integer null
    check (total_quantity is null or total_quantity > 0),
  -- 발급된 누적 수 (PR 2의 발급 RPC에서 자동 증감)
  issued_count integer not null default 0
    check (issued_count >= 0),

  -- 발급 방식
  --  admin_assigned: 어드민이 특정 회원/전체에 push (PR 2)
  --  code:           회원이 코드 입력으로 직접 발급 (PR 2)
  --  download:       회원이 쿠폰 페이지에서 다운로드 (PR 2)
  issuance_type text not null
    check (issuance_type in ('admin_assigned', 'code', 'download')),
  -- code 형식일 때만 사용. 대소문자 구분, unique
  code text null unique,

  -- 비활성화하면 신규 발급/사용 모두 막힘 (이미 발급된 member_coupons는 영향 없음)
  is_active boolean not null default true,

  created_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 발급 방식이 'code'면 code가 반드시 있어야 함
alter table public.coupons drop constraint if exists coupons_code_required_for_code_type;
alter table public.coupons add constraint coupons_code_required_for_code_type
  check (issuance_type <> 'code' or (code is not null and length(code) > 0));

-- percentage 쿠폰은 0–100
alter table public.coupons drop constraint if exists coupons_percentage_range;
alter table public.coupons add constraint coupons_percentage_range
  check (discount_type <> 'percentage' or (discount_value between 1 and 100));

-- 유효기간 순서
alter table public.coupons drop constraint if exists coupons_valid_range;
alter table public.coupons add constraint coupons_valid_range
  check (valid_from is null or valid_until is null or valid_from <= valid_until);

create index if not exists idx_coupons_active_created_at
  on public.coupons (is_active, created_at desc);

-- updated_at 자동 갱신
create or replace function public.tg_coupons_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists tg_coupons_updated_at on public.coupons;
create trigger tg_coupons_updated_at
  before update on public.coupons
  for each row execute function public.tg_coupons_set_updated_at();

-- ── RLS ────────────────────────────────────────────────────────────
alter table public.coupons enable row level security;

-- 어드민만 모든 작업 가능. 일반 회원은 PR 2의 RPC를 통해서만 간접 조회.
drop policy if exists coupons_admin_all on public.coupons;
create policy coupons_admin_all on public.coupons
  for all
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ── Admin RPCs ─────────────────────────────────────────────────────

-- 쿠폰 생성. JSONB로 모든 필드를 받아 어드민 폼이 자율 설정 가능하게.
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

-- 쿠폰 수정. 부분 업데이트 (전달된 필드만 갱신).
create or replace function public.admin_update_coupon(p_coupon_id bigint, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.coupons%rowtype;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_existing from public.coupons where id = p_coupon_id;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
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

-- 활성/비활성 토글 (delete 대신 — 이미 발급된 member_coupons 보호).
create or replace function public.admin_set_coupon_active(p_coupon_id bigint, p_is_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  update public.coupons set is_active = p_is_active where id = p_coupon_id;

  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;

  return jsonb_build_object('success', true, 'coupon_id', p_coupon_id, 'is_active', p_is_active);
end;
$$;

-- 어드민 쿠폰 목록.
create or replace function public.admin_list_coupons(
  p_search text default null,
  p_only_active boolean default false,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select to_jsonb(c.*) as row_data
    from public.coupons c
    where
      (p_search is null or p_search = ''
        or c.title ilike '%' || p_search || '%'
        or coalesce(c.code, '') ilike '%' || p_search || '%')
      and (p_only_active = false or c.is_active = true)
    order by c.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.admin_create_coupon(jsonb) to authenticated;
grant execute on function public.admin_update_coupon(bigint, jsonb) to authenticated;
grant execute on function public.admin_set_coupon_active(bigint, boolean) to authenticated;
grant execute on function public.admin_list_coupons(text, boolean, integer, integer) to authenticated;
