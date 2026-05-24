-- Phase 5: 어드민 audit·권한 역할·쿠폰 예산 cap·평문 계좌 다운로드 audit
--
-- 본 마이그레이션은 전부 additive (DROP·ALTER TYPE·RLS 약화 없음).
-- 기존 admin_block_member / admin_unblock_member / admin_users / coupons 동작은
-- 유지하면서 다음을 추가한다:
--   1. member_block_history — 회원 차단·해제 행위의 영구 audit
--   2. admin_users.role + 헬퍼 함수 — 슈퍼관리자/운영자/CS 역할 구분
--   3. coupons.budget_cap_amount + used_amount + 자동 비활성 트리거 — 예산 초과 방지
--   4. settlement_export_audit + admin_log_settlement_export — 평문 계좌 다운로드 추적

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 회원 차단 audit 히스토리
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.member_block_history (
  id bigserial primary key,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  admin_user_id uuid null references auth.users(id) on delete set null,
  admin_email text not null,
  action text not null check (action in ('block', 'unblock')),
  reason text null,
  notify_user boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_member_block_history_target on public.member_block_history(target_user_id, created_at desc);
create index if not exists idx_member_block_history_admin on public.member_block_history(admin_user_id, created_at desc);

alter table public.member_block_history enable row level security;

drop policy if exists member_block_history_admin_select on public.member_block_history;
create policy member_block_history_admin_select
  on public.member_block_history
  for select
  to authenticated
  using (public.is_admin_user());

-- INSERT는 RPC만 수행 (security definer); 어드민이라도 직접 INSERT는 차단.

-- admin_block_member: notify_user 인자 추가 + history 기록.
-- 기존 호출(2-arg)은 그대로 동작.
create or replace function public.admin_block_member(
  p_user_id uuid,
  p_reason text default null,
  p_notify_user boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_email text;
  v_admin_user_id uuid;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_admin_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_admin_user_id := auth.uid();

  update public.member_profiles
  set
    is_blocked = true,
    blocked_at = now(),
    block_reason = nullif(btrim(p_reason), ''),
    updated_at = now()
  where user_id = p_user_id;

  if not found then
    raise exception '해당 회원을 찾을 수 없습니다.';
  end if;

  insert into public.member_block_history(
    target_user_id, admin_user_id, admin_email, action, reason, notify_user
  ) values (
    p_user_id, v_admin_user_id, v_admin_email, 'block', nullif(btrim(p_reason), ''), coalesce(p_notify_user, false)
  );

  return jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'is_blocked', true,
    'audit_logged', true
  );
end;
$$;

create or replace function public.admin_unblock_member(
  p_user_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_email text;
  v_admin_user_id uuid;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_admin_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_admin_user_id := auth.uid();

  update public.member_profiles
  set
    is_blocked = false,
    blocked_at = null,
    block_reason = null,
    updated_at = now()
  where user_id = p_user_id;

  if not found then
    raise exception '해당 회원을 찾을 수 없습니다.';
  end if;

  insert into public.member_block_history(
    target_user_id, admin_user_id, admin_email, action, reason, notify_user
  ) values (
    p_user_id, v_admin_user_id, v_admin_email, 'unblock', nullif(btrim(p_reason), ''), false
  );

  return jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'is_blocked', false,
    'audit_logged', true
  );
end;
$$;

-- 차단 이력 조회 RPC (회원 상세 모달용)
create or replace function public.admin_get_member_block_history(p_user_id uuid)
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
    select jsonb_build_object(
      'id', mbh.id,
      'action', mbh.action,
      'admin_email', mbh.admin_email,
      'reason', mbh.reason,
      'notify_user', mbh.notify_user,
      'created_at', mbh.created_at
    ) as row_data
    from public.member_block_history mbh
    where mbh.target_user_id = p_user_id
    order by mbh.created_at desc
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.admin_block_member(uuid, text, boolean) to authenticated;
grant execute on function public.admin_unblock_member(uuid, text) to authenticated;
grant execute on function public.admin_get_member_block_history(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 어드민 역할 — role 컬럼 + 헬퍼
-- ─────────────────────────────────────────────────────────────────────────────
-- enum 대신 text + check 제약 (enum은 후속 추가가 까다로움)
alter table public.admin_users
  add column if not exists role text not null default 'super'
    check (role in ('super', 'ops', 'cs'));

-- 기존 admin은 모두 super (default가 super라 새 컬럼은 자동으로 채워짐)

create or replace function public.current_admin_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select au.role
  from public.admin_users au
  where lower(au.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  limit 1;
$$;

create or replace function public.is_admin_user_with_role(p_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_users au
    where lower(au.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and (
        au.role = p_role
        or au.role = 'super'  -- super는 모든 역할 권한 포함
      )
  );
$$;

grant execute on function public.current_admin_role() to authenticated;
grant execute on function public.is_admin_user_with_role(text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 쿠폰 예산 cap — 누적 할인액이 cap 초과 시 자동 비활성
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.coupons
  add column if not exists budget_cap_amount integer null,
  add column if not exists used_amount integer not null default 0;

comment on column public.coupons.budget_cap_amount is
  '쿠폰이 회사에 줄 수 있는 최대 누적 할인액(원). NULL이면 무제한. 정률 쿠폰의 폭주 사고 방어 장치.';
comment on column public.coupons.used_amount is
  '쿠폰이 실제로 적용된 누적 할인액(원). 결제 시 created_order의 coupon_discount_amount만큼 증가.';

-- member_coupons.used_at이 NULL → NOT NULL로 바뀔 때 (= 사용 처리)
-- 연결된 order의 coupon_discount_amount를 coupons.used_amount에 누적.
-- 누적이 cap을 넘으면 is_active=false로 즉시 비활성.
create or replace function public._coupons_track_used_amount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_discount integer;
  v_cap integer;
  v_total integer;
begin
  if old.used_at is not null then
    return new;  -- 이미 사용 처리된 행의 재업데이트 무시
  end if;
  if new.used_at is null then
    return new;
  end if;
  if new.used_order_id is null then
    return new;
  end if;

  select coalesce(coupon_discount_amount, 0) into v_discount
  from public.orders
  where id = new.used_order_id;

  if v_discount is null or v_discount <= 0 then
    return new;
  end if;

  update public.coupons
  set used_amount = used_amount + v_discount
  where id = new.coupon_id
  returning budget_cap_amount, used_amount into v_cap, v_total;

  if v_cap is not null and v_total >= v_cap then
    update public.coupons
    set is_active = false
    where id = new.coupon_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_coupons_track_used_amount on public.member_coupons;
create trigger trg_coupons_track_used_amount
  after update of used_at on public.member_coupons
  for each row execute function public._coupons_track_used_amount();

-- 쿠폰 발급 RPC에서 잠재 손실 시뮬레이션 도움이 되도록 helper도 노출.
-- frontend는 (활성 회원 수 × 1인당 최대 할인)을 미리 보여줄 수 있음.
create or replace function public.admin_estimate_coupon_max_loss(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_eligible_count integer;
  v_per_user_max integer;
  v_total_max integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;

  -- 일반 회원 수 (admin 제외)
  select count(*) into v_eligible_count
  from public.member_profiles mp
  where not exists (
    select 1 from public.admin_users au
    where lower(au.email) = lower(coalesce(mp.email, ''))
  );

  -- 1인당 최대 할인액
  if v_coupon.discount_type = 'fixed' then
    v_per_user_max := v_coupon.discount_value;
  elsif v_coupon.discount_type = 'percentage' then
    if v_coupon.max_discount_amount is not null then
      v_per_user_max := v_coupon.max_discount_amount;
    else
      -- 캡 없는 정률 — 위험. 평균 객단가 5만원 가정으로 추정.
      v_per_user_max := (50000 * v_coupon.discount_value) / 100;
    end if;
  elsif v_coupon.discount_type = 'free_shipping' then
    v_per_user_max := 3500;
  else
    v_per_user_max := v_coupon.discount_value;
  end if;

  v_total_max := v_eligible_count * v_per_user_max;

  return jsonb_build_object(
    'eligible_member_count', v_eligible_count,
    'per_user_max_amount', v_per_user_max,
    'total_max_loss', v_total_max,
    'budget_cap_amount', v_coupon.budget_cap_amount,
    'current_used_amount', v_coupon.used_amount,
    'percentage_no_max_discount_warning', v_coupon.discount_type = 'percentage' and v_coupon.max_discount_amount is null
  );
end;
$$;

grant execute on function public.admin_estimate_coupon_max_loss(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 평문 계좌 다운로드 audit — 정산금 사고 추적
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.settlement_export_audit (
  id bigserial primary key,
  admin_user_id uuid null references auth.users(id) on delete set null,
  admin_email text not null,
  exported_settlement_ids bigint[] not null default '{}'::bigint[],
  row_count integer not null default 0,
  is_plain_text boolean not null default false,
  file_name text null,
  client_tag text null,
  created_at timestamptz not null default now()
);

create index if not exists idx_settlement_export_audit_admin
  on public.settlement_export_audit(admin_email, created_at desc);
create index if not exists idx_settlement_export_audit_plain
  on public.settlement_export_audit(is_plain_text, created_at desc) where is_plain_text = true;

alter table public.settlement_export_audit enable row level security;

drop policy if exists settlement_export_audit_admin_select on public.settlement_export_audit;
create policy settlement_export_audit_admin_select
  on public.settlement_export_audit
  for select
  to authenticated
  using (public.is_admin_user());

-- INSERT는 RPC로만 수행 (security definer)
create or replace function public.admin_log_settlement_export(
  p_settlement_ids bigint[],
  p_is_plain_text boolean,
  p_file_name text default null,
  p_client_tag text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_email text;
  v_admin_user_id uuid;
  v_row_count integer;
  v_audit_id bigint;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_admin_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_admin_user_id := auth.uid();
  v_row_count := coalesce(array_length(p_settlement_ids, 1), 0);

  insert into public.settlement_export_audit(
    admin_user_id, admin_email,
    exported_settlement_ids, row_count, is_plain_text,
    file_name, client_tag
  ) values (
    v_admin_user_id, v_admin_email,
    coalesce(p_settlement_ids, '{}'::bigint[]), v_row_count, coalesce(p_is_plain_text, false),
    nullif(btrim(coalesce(p_file_name, '')), ''),
    nullif(btrim(coalesce(p_client_tag, '')), '')
  )
  returning id into v_audit_id;

  return jsonb_build_object(
    'success', true,
    'audit_id', v_audit_id,
    'row_count', v_row_count,
    'is_plain_text', coalesce(p_is_plain_text, false),
    'recorded_at', now()
  );
end;
$$;

grant execute on function public.admin_log_settlement_export(bigint[], boolean, text, text) to authenticated;
