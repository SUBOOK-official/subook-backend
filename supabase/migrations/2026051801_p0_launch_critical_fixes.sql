-- 출시 차단급 P0 핫픽스 (2026-05-18 launch readiness audit)
--
-- 1) create_settlements_for_order: 2026051503에서 calculate_settlement_fee_percent 인자
--    순서가 (pickup_date, unit_price)로 뒤바뀌어 정산 trigger가 항상 실패하던 문제 복구.
--    동시에 계좌 암호화 컬럼(account_number_ciphertext / account_number_last4)을 포함한
--    2026041206 버전의 형태를 유지하면서 fee_amount 정책은 2026051503의 round() 유지.
-- 2) get_account_encryption_key: 'subook-local-development-account-key' 하드코딩 fallback 제거.
--    GUC가 설정되지 않으면 즉시 RAISE → 운영자가 prod에 키를 설정하지 않으면 모든
--    encrypt/decrypt가 fail-close. 마이그레이션 자체는 통과하지만 WARNING으로 안내.
-- 3) assert_terms_agreed_for_user(): orders / pickup_requests 신규 INSERT 시 약관 동의 강제.
--    OAuth 사용자가 consent 페이지를 우회해도 DB 차원에서 차단. service_role / admin은 우회.
-- 4) expire_unpaid_orders: row_count 누적 버그 + pg_cron(15분 단위) 스케줄링 추가.
-- 5) get_current_auth_account_role: 응답에 is_blocked, block_reason 노출 → 프론트가
--    차단 회원을 로그인 직후 감지하고 로그아웃시킬 수 있도록.
-- 6) orders_create_settlements_after_confirm 트리거 안전 재생성 (idempotent).

begin;

-- ============================================================================
-- 0) 누락된 암호화 컬럼 보강 (drift fix)
--    schema_migrations에는 2026041206이 기록되어 있으나 실제 prod에는 컬럼이 추가되지
--    않은 상태(2026-05-18 진단). 함수 본체가 이 컬럼을 참조해 첫 호출 시 실패하던 문제 해소.
--    데이터 0건 상태에서 idempotent하게 추가하므로 데이터 손실 없음.
-- ============================================================================
alter table public.member_settlement_accounts
  add column if not exists account_number_ciphertext bytea null,
  add column if not exists account_number_last4 text null;

alter table public.member_settlement_accounts
  alter column account_number drop not null;

alter table public.pickup_requests
  add column if not exists settlement_account_number_ciphertext bytea null,
  add column if not exists settlement_account_last4 text null;

alter table public.pickup_requests
  alter column settlement_account_number drop not null;

alter table public.settlements
  add column if not exists account_number_ciphertext bytea null,
  add column if not exists account_number_last4 text null;

create index if not exists idx_member_settlement_accounts_last4
  on public.member_settlement_accounts (user_id, account_number_last4);

-- ============================================================================
-- 1) create_settlements_for_order 인자 순서 복구
-- ============================================================================
drop function if exists public.create_settlements_for_order(bigint);

create or replace function public.create_settlements_for_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_item record;
  v_unit_price integer;
  v_sale_amount integer;
  v_fee_percent numeric(5, 2);
  v_fee_amount integer;
  v_inserted_count integer := 0;
begin
  select * into v_order
    from public.orders
   where id = p_order_id
     and status = 'confirmed'
     and confirmed_at is not null;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'order_not_confirmed');
  end if;

  for v_item in
    select
      oi.id        as order_item_id,
      oi.book_id,
      oi.quantity,
      oi.unit_price,
      oi.total_price,
      b.shipment_id,
      s.user_id    as seller_user_id,
      s.pickup_date,
      msa.bank_name,
      msa.account_number_ciphertext,
      coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number)) as account_number_last4,
      msa.account_holder
    from public.order_items oi
    join public.books b
      on b.id = oi.book_id
    left join public.shipments s
      on s.id = b.shipment_id
    left join lateral (
      select
        account.bank_name,
        account.account_number,
        account.account_number_ciphertext,
        account.account_number_last4,
        account.account_holder
      from public.member_settlement_accounts account
      where account.user_id = s.user_id
      order by account.is_default desc, account.created_at desc, account.id desc
      limit 1
    ) msa on true
    where oi.order_id = p_order_id
  loop
    -- 자체매입(셀러 미연결) 건은 정산 대상 아님
    if v_item.seller_user_id is null then
      continue;
    end if;

    v_sale_amount := greatest(
      0,
      coalesce(v_item.total_price,
               v_item.unit_price * greatest(1, coalesce(v_item.quantity, 1)),
               0)
    );
    if v_sale_amount <= 0 then
      continue;
    end if;

    v_unit_price := greatest(
      0,
      coalesce(
        v_item.unit_price,
        case
          when coalesce(v_item.quantity, 0) > 0
            then floor(v_sale_amount::numeric / v_item.quantity)::integer
          else v_sale_amount
        end,
        0
      )
    );

    -- ⚠️ FIX: signature is (p_unit_price integer, p_pickup_date date) — 2026051503가
    -- 뒤바꿔 호출하던 인자 순서를 복구. 이 한 줄이 정산 파이프라인 전체를 살린다.
    v_fee_percent := public.calculate_settlement_fee_percent(v_unit_price, v_item.pickup_date);

    -- 2026051503에서 도입한 round 정책 유지 (floor → round)
    v_fee_amount := round(v_sale_amount * (v_fee_percent / 100))::integer;

    if v_sale_amount - v_fee_amount <= 0 then
      raise notice 'create_settlements_for_order: net_amount<=0 skip order=% book=%',
        p_order_id, v_item.book_id;
      continue;
    end if;

    insert into public.settlements (
      seller_user_id, order_id, order_item_id, book_id,
      sale_amount, fee_percent, fee_amount, net_amount,
      status, scheduled_date,
      bank_name, account_number, account_number_ciphertext, account_number_last4, account_holder
    )
    values (
      v_item.seller_user_id, p_order_id, v_item.order_item_id, v_item.book_id,
      v_sale_amount, v_fee_percent, v_fee_amount, v_sale_amount - v_fee_amount,
      'pending',
      public.add_business_days((v_order.confirmed_at at time zone 'Asia/Seoul')::date, 3),
      v_item.bank_name,
      public.mask_account_number(v_item.account_number_last4),
      v_item.account_number_ciphertext,
      v_item.account_number_last4,
      v_item.account_holder
    )
    on conflict (order_id, book_id) do nothing;

    if found then
      v_inserted_count := v_inserted_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'inserted_count', v_inserted_count
  );
end;
$$;

revoke execute on function public.create_settlements_for_order(bigint) from public;
revoke execute on function public.create_settlements_for_order(bigint) from authenticated;
grant execute on function public.create_settlements_for_order(bigint) to service_role;

-- ============================================================================
-- 6) 트리거 재확인 (orders status='confirmed' → create_settlements_for_order)
--    2026041203에서 정의된 트리거가 누락되지 않도록 idempotent 재생성.
-- ============================================================================
drop trigger if exists orders_create_settlements_after_confirm on public.orders;
create trigger orders_create_settlements_after_confirm
  after insert or update of status, confirmed_at on public.orders
  for each row
  execute function public.create_order_settlements_after_confirm();

-- ============================================================================
-- 2) get_account_encryption_key — private table 기반 fail-close
--    Supabase postgres 사용자는 ALTER DATABASE SET 권한이 없어 GUC 설정 불가.
--    GUC fallback 우선 시도, 없으면 private 테이블에서 조회. 둘 다 없으면 RAISE.
--    하드코딩 fallback('subook-local-development-account-key')은 제거.
-- ============================================================================

-- private 스키마 + 테이블: service_role만 SELECT, 나머지 거부 (RLS 우회용으로 일부러 RLS 미사용)
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

create table if not exists private.app_secrets (
  key text primary key,
  value text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

revoke all on table private.app_secrets from public, anon, authenticated;
grant select, insert, update, delete on table private.app_secrets to service_role;

create or replace function public.get_account_encryption_key()
returns text
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_key text;
begin
  -- 1순위: GUC (운영자가 Supabase Dashboard에서 설정한 경우)
  v_key := coalesce(
    nullif(current_setting('app.account_encryption_key', true), ''),
    nullif(current_setting('app.settings.account_encryption_key', true), ''),
    nullif(current_setting('subook.account_encryption_key', true), '')
  );

  if v_key is not null then
    return v_key;
  end if;

  -- 2순위: private.app_secrets 테이블
  select value into v_key
    from private.app_secrets
   where key = 'account_encryption_key';

  if v_key is not null and length(v_key) > 0 then
    return v_key;
  end if;

  raise exception 'Account encryption key is not configured. Insert into private.app_secrets (key=''account_encryption_key'', value=''<strong-secret>'').'
    using errcode = 'configuration_required';
end;
$$;

-- 운영자 안내: 마이그레이션 자체는 통과시키되 키 미설정 시 WARNING.
do $$
declare
  v_test text;
begin
  begin
    v_test := public.get_account_encryption_key();
    raise notice 'Account encryption key is configured (length=%)', length(v_test);
  exception
    when others then
      raise warning 'WARNING: account encryption key is NOT configured. Insert into private.app_secrets before first settlement account / pickup request.';
  end;
end $$;

-- ============================================================================
-- 3) 약관 동의 강제 트리거 (orders + pickup_requests)
-- ============================================================================
create or replace function public.assert_terms_agreed_for_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_terms timestamptz;
  v_privacy timestamptz;
begin
  if p_user_id is null then
    return;
  end if;

  select terms_agreed_at, privacy_agreed_at
    into v_terms, v_privacy
    from public.member_profiles
   where user_id = p_user_id;

  if v_terms is null or v_privacy is null then
    raise exception '약관 및 개인정보 처리방침 동의가 필요합니다.'
      using hint = 'OAuth 가입 직후라면 약관 동의 페이지를 완료해주세요.';
  end if;
end;
$$;

revoke execute on function public.assert_terms_agreed_for_user(uuid) from public, anon;
grant execute on function public.assert_terms_agreed_for_user(uuid) to authenticated, service_role;

create or replace function public.trigger_assert_terms_agreed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 시스템 호출(cron, service_role 등 JWT 없음)은 통과
  if auth.uid() is null then
    return new;
  end if;

  -- 어드민이 사용자 대신 등록하는 경우 통과 (어드민은 member_profiles 없음)
  if public.is_admin_user() then
    return new;
  end if;

  -- new.user_id가 caller와 다른 비정상 케이스는 차단 — 단순화: caller만 검사
  perform public.assert_terms_agreed_for_user(auth.uid());

  return new;
end;
$$;

drop trigger if exists orders_assert_terms_agreed on public.orders;
create trigger orders_assert_terms_agreed
  before insert on public.orders
  for each row
  execute function public.trigger_assert_terms_agreed();

drop trigger if exists pickup_requests_assert_terms_agreed on public.pickup_requests;
create trigger pickup_requests_assert_terms_agreed
  before insert on public.pickup_requests
  for each row
  execute function public.trigger_assert_terms_agreed();

-- ============================================================================
-- 4) expire_unpaid_orders 누적 버그 수정 + pg_cron 15분 단위 스케줄
-- ============================================================================
create or replace function public.expire_unpaid_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_count   integer := 0;
  v_coupon_restored integer := 0;
  v_iter_count      integer;
  v_order           record;
begin
  for v_order in
    select id, applied_member_coupon_id
      from public.orders
     where status = 'pending'
       and payment_status = 'pending'
       and created_at < now() - interval '24 hours'
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

  return jsonb_build_object(
    'expired_count', v_expired_count,
    'coupons_restored', v_coupon_restored,
    'executed_at', now()
  );
end;
$$;

grant execute on function public.expire_unpaid_orders() to service_role;

do $$
begin
  if to_regnamespace('cron') is not null then
    begin
      perform cron.unschedule('subook-expire-unpaid-orders');
    exception when others then
      null;
    end;

    perform cron.schedule(
      'subook-expire-unpaid-orders',
      '*/15 * * * *',
      $job$ select public.expire_unpaid_orders(); $job$
    );
  end if;
exception
  when insufficient_privilege or undefined_function or undefined_table then
    null;
end $$;

-- ============================================================================
-- 5) get_current_auth_account_role: is_blocked, block_reason 노출
-- ============================================================================
drop function if exists public.get_current_auth_account_role();

create or replace function public.get_current_auth_account_role()
returns table (
  account_role text,
  user_id uuid,
  email text,
  name text,
  nickname text,
  phone text,
  marketing_opt_in boolean,
  email_verified_at timestamptz,
  terms_agreed_at timestamptz,
  privacy_agreed_at timestamptz,
  is_blocked boolean,
  block_reason text,
  withdrawal_requested_at timestamptz,
  withdrawal_scheduled_at timestamptz,
  personal_data_erased_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with viewer as (
    select
      auth.uid() as user_id,
      lower(coalesce(auth.jwt() ->> 'email', '')) as email
  )
  select
    case
      when viewer.user_id is null then 'guest'
      when exists (
        select 1
          from public.admin_users au
         where lower(au.email) = viewer.email
      ) then 'admin'
      when mp.personal_data_erased_at is not null then 'withdrawn'
      when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
      when mp.user_id is not null then 'member'
      else 'unknown'
    end as account_role,
    viewer.user_id,
    coalesce(mp.email, viewer.email) as email,
    mp.name,
    mp.nickname,
    mp.phone,
    coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
    mp.email_verified_at,
    mp.terms_agreed_at,
    mp.privacy_agreed_at,
    coalesce(mp.is_blocked, false) as is_blocked,
    mp.block_reason,
    mp.withdrawal_requested_at,
    mp.withdrawal_scheduled_at,
    mp.personal_data_erased_at
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

grant execute on function public.get_current_auth_account_role() to authenticated;

commit;
