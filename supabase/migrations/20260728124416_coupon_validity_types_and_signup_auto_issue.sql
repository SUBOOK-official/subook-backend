-- 쿠폰 사용기간 유형 확장 + 회원가입 자동지급 (구 식스샵 쿠폰 설정 패리티, 2026-07-28)
--
-- 식스샵 '기한 설정 유형' 3종을 지원한다:
--   · 시작일로부터 무기한        = valid_from(선택) + valid_until null + valid_days null
--   · 시작일과 종료일 설정       = valid_from(선택) + valid_until
--   · 지급일 기준 사용 기간 설정 = valid_days (발급 시점 + N일 = member_coupons.expires_at)
-- '쿠폰 자동 지급 조건 - 회원 가입 시 지급' = coupons.issue_on_signup + member_profiles
-- INSERT 트리거.
--
-- 정책 결정(2026-07-28, 사용자): 가입 쿠폰 어뷰징 방어용 전화번호 인증 연동은 폐지.
--   깡계정 반복 가입 리스크는 인지하고 수용 — 문제가 실제로 생기면 그때 대응.
--   (기존 OTP 인프라(20260710175927)는 제거하지 않고 미연동 상태로 둔다.)
--
-- 겸사 수리: admin_create_coupon/admin_update_coupon이 budget_cap_amount를 저장하지
--   않던 누락(어드민 폼은 보내는데 RPC가 무시 → 예산 자동 비활성 트리거가 무력화됨).
--
-- 비파괴: 컬럼 추가(additive) + CREATE OR REPLACE + 트리거 신설.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) coupons 컬럼 추가
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.coupons
  add column if not exists valid_days integer null
    check (valid_days is null or valid_days > 0),
  add column if not exists issue_on_signup boolean not null default false;

comment on column public.coupons.valid_days is
  '지급일 기준 사용 기간(일). 설정 시 발급 시점 + N일이 member_coupons.expires_at이 된다. valid_until과 동시 설정 불가.';
comment on column public.coupons.issue_on_signup is
  '회원 가입 시 자동 지급 여부 (member_profiles INSERT 트리거가 발급).';

-- 절대 종료일과 상대 기간은 동시 설정 불가 (기한 유형이 셋 중 하나로 유일해지도록)
alter table public.coupons drop constraint if exists coupons_valid_days_xor_until;
alter table public.coupons add constraint coupons_valid_days_xor_until
  check (valid_days is null or valid_until is null);

-- 가입 자동지급 대상 조회용
create index if not exists idx_coupons_signup_active
  on public.coupons (issue_on_signup, is_active)
  where issue_on_signup = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 발급 시 만료 계산 헬퍼 — 4개 발급 경로가 공유
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.compute_coupon_member_expiry(
  p_valid_days integer,
  p_valid_until timestamptz
)
returns timestamptz
language sql
stable
as $$
  select case
    when p_valid_days is not null then now() + make_interval(days => p_valid_days)
    else p_valid_until
  end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 발급 RPC 4종: expires_at 계산 교체
--    (base: 2026050602 — 변경점은 expires_at 표현식뿐, 나머지 검증 로직 동일)
-- ─────────────────────────────────────────────────────────────────────────────

-- 3-1) 코드 입력 발급
create or replace function public.claim_coupon_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_coupon record;
  v_member_coupon_id bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_code is null or btrim(p_code) = '' then
    raise exception '쿠폰 코드를 입력해 주세요.';
  end if;

  select * into v_coupon
  from public.coupons
  where lower(code) = lower(btrim(p_code))
  for update;

  if not found then
    raise exception '유효하지 않은 쿠폰 코드입니다.';
  end if;

  if v_coupon.issuance_type <> 'code' then
    raise exception '코드 입력 가능한 쿠폰이 아닙니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰입니다.';
  end if;
  if v_coupon.valid_from is not null and v_coupon.valid_from > now() then
    raise exception '아직 사용할 수 없는 쿠폰입니다.';
  end if;
  if v_coupon.valid_until is not null and v_coupon.valid_until < now() then
    raise exception '만료된 쿠폰입니다.';
  end if;
  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    raise exception '발급 한도를 초과했습니다.';
  end if;
  if exists (
    select 1 from public.member_coupons
    where coupon_id = v_coupon.id and user_id = v_user_id
  ) then
    raise exception '이미 등록된 쿠폰입니다.';
  end if;

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (
    v_coupon.id,
    v_user_id,
    public.compute_coupon_member_expiry(v_coupon.valid_days, v_coupon.valid_until)
  )
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = v_coupon.id;

  return jsonb_build_object('success', true, 'member_coupon_id', v_member_coupon_id);
end;
$$;

-- 3-2) 다운로드 발급
create or replace function public.claim_coupon_for_download(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_coupon record;
  v_member_coupon_id bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;
  if v_coupon.issuance_type <> 'download' then
    raise exception '다운로드 가능한 쿠폰이 아닙니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰입니다.';
  end if;
  if v_coupon.valid_from is not null and v_coupon.valid_from > now() then
    raise exception '아직 사용할 수 없는 쿠폰입니다.';
  end if;
  if v_coupon.valid_until is not null and v_coupon.valid_until < now() then
    raise exception '만료된 쿠폰입니다.';
  end if;
  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    raise exception '발급 한도를 초과했습니다.';
  end if;
  if exists (
    select 1 from public.member_coupons
    where coupon_id = v_coupon.id and user_id = v_user_id
  ) then
    raise exception '이미 받은 쿠폰입니다.';
  end if;

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (
    v_coupon.id,
    v_user_id,
    public.compute_coupon_member_expiry(v_coupon.valid_days, v_coupon.valid_until)
  )
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = v_coupon.id;

  return jsonb_build_object('success', true, 'member_coupon_id', v_member_coupon_id);
end;
$$;

-- 3-3) 어드민 → 특정 회원 발급
create or replace function public.admin_issue_coupon_to_user(
  p_coupon_id bigint,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_member_coupon_id bigint;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception '회원을 찾을 수 없습니다.';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰은 발급할 수 없습니다.';
  end if;
  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    raise exception '발급 한도를 초과했습니다.';
  end if;

  -- code/download형은 한 사람당 1매 제한 (admin이 push해도 동일 정책)
  if v_coupon.issuance_type in ('code', 'download') then
    if exists (
      select 1 from public.member_coupons
      where coupon_id = p_coupon_id and user_id = p_user_id
    ) then
      raise exception '이 회원은 이미 이 쿠폰을 가지고 있습니다.';
    end if;
  end if;

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (
    p_coupon_id,
    p_user_id,
    public.compute_coupon_member_expiry(v_coupon.valid_days, v_coupon.valid_until)
  )
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = p_coupon_id;

  return jsonb_build_object('success', true, 'member_coupon_id', v_member_coupon_id);
end;
$$;

-- 3-4) 어드민 → 전체 회원 발급
create or replace function public.admin_issue_coupon_to_all(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_inserted integer;
  v_remaining integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰은 발급할 수 없습니다.';
  end if;

  if v_coupon.total_quantity is null then
    v_remaining := 1000000;  -- 사실상 무제한
  else
    v_remaining := v_coupon.total_quantity - v_coupon.issued_count;
    if v_remaining <= 0 then
      raise exception '발급 한도를 초과했습니다.';
    end if;
  end if;

  with eligible as (
    select mp.user_id
    from public.member_profiles mp
    where not exists (
      select 1 from public.admin_users au
      where lower(au.email) = lower(mp.email)
    )
    and (
      v_coupon.issuance_type not in ('code', 'download')
      or not exists (
        select 1 from public.member_coupons mc
        where mc.coupon_id = p_coupon_id and mc.user_id = mp.user_id
      )
    )
    limit v_remaining
  )
  insert into public.member_coupons (coupon_id, user_id, expires_at)
  select
    p_coupon_id,
    user_id,
    public.compute_coupon_member_expiry(v_coupon.valid_days, v_coupon.valid_until)
  from eligible;

  get diagnostics v_inserted = row_count;

  if v_inserted > 0 then
    update public.coupons set issued_count = issued_count + v_inserted where id = p_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'inserted_count', v_inserted);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 회원가입 자동지급 트리거 (member_profiles INSERT)
--    · 활성 + issue_on_signup + 발급 가능 창(valid_from/until) + 수량 여유인 쿠폰 전부 1매씩
--    · 운영진(admin_users 이메일)은 제외 — admin_issue_coupon_to_all과 동일 정책
--    · 예외는 전부 삼킨다: 쿠폰 발급 실패가 회원가입을 절대 막으면 안 됨
--    ⚠ 어뷰징 방어(전화번호 인증 등) 없음 — 2026-07-28 정책 결정으로 의도된 상태
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.issue_signup_coupons_for_new_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
begin
  -- 운영진 계정 가입은 제외
  if exists (
    select 1 from public.admin_users au
    where lower(au.email) = lower(coalesce(new.email, ''))
  ) then
    return new;
  end if;

  for v_coupon in
    select * from public.coupons
    where issue_on_signup = true
      and is_active = true
      and (valid_from is null or valid_from <= now())
      and (valid_until is null or valid_until >= now())
    order by id
    for update
  loop
    -- 수량 한도·중복 방어 (재실행/동시 가입 안전)
    if v_coupon.total_quantity is not null
       and v_coupon.issued_count >= v_coupon.total_quantity then
      continue;
    end if;
    if exists (
      select 1 from public.member_coupons
      where coupon_id = v_coupon.id and user_id = new.user_id
    ) then
      continue;
    end if;

    insert into public.member_coupons (coupon_id, user_id, expires_at)
    values (
      v_coupon.id,
      new.user_id,
      public.compute_coupon_member_expiry(v_coupon.valid_days, v_coupon.valid_until)
    );

    update public.coupons set issued_count = issued_count + 1 where id = v_coupon.id;
  end loop;

  return new;
exception when others then
  -- 쿠폰 지급 실패가 가입을 막으면 안 됨
  return new;
end;
$$;

drop trigger if exists trg_member_profiles_signup_coupons on public.member_profiles;
create trigger trg_member_profiles_signup_coupons
  after insert on public.member_profiles
  for each row
  execute function public.issue_signup_coupons_for_new_member();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) admin_create_coupon / admin_update_coupon: 신규 필드 + budget_cap_amount 수리
--    (base: 20260531020000 — 정률 상한 검증 유지)
-- ─────────────────────────────────────────────────────────────────────────────
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
    auth.uid()
  )
  returning id into v_id;

  return jsonb_build_object('success', true, 'coupon_id', v_id);
exception
  when unique_violation then
    raise exception '이미 사용 중인 쿠폰 코드입니다.';
end;
$$;

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
    is_active = coalesce((p_payload->>'is_active')::boolean, is_active)
  where id = p_coupon_id;

  return jsonb_build_object('success', true, 'coupon_id', p_coupon_id);
exception
  when unique_violation then
    raise exception '이미 사용 중인 쿠폰 코드입니다.';
end;
$$;

commit;

notify pgrst, 'reload schema';
