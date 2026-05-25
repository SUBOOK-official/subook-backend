-- 식스샵(이전 수북) 회원 데이터 lazy 이전.
-- auth.users는 미리 만들지 않음. 사용자가 같은 이메일로 가입(OTP)할 때만 member_profiles
-- 트리거가 legacy_sixshop_customers 매칭 row에서 phone·마케팅·배송지·계좌를 자동 backfill.
--
-- 모두 additive. DROP·ALTER TYPE·RLS 약화 없음.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. legacy_sixshop_customers — 식스샵 회원 staging
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.legacy_sixshop_customers (
  id bigserial primary key,
  email text not null unique,  -- lowercase normalized
  sixshop_id text null,
  name text null,
  phone text null,
  marketing_opt_in_email boolean not null default false,
  marketing_opt_in_sms boolean not null default false,

  -- 환불 계좌 (식스샵 raw + parsed)
  refund_account_raw text null,
  refund_bank_name text null,
  refund_account_number_plain text null,  -- import 시점 평문. backfill 후 nullify해도 됨.
  refund_account_holder text null,

  -- 기본 배송지 (식스샵 raw + parsed)
  default_address_raw text null,
  shipping_postal_code text null,
  shipping_address_line1 text null,
  shipping_address_line2 text null,

  signed_up_at_sixshop timestamptz null,
  last_login_at_sixshop timestamptz null,

  imported_at timestamptz not null default now(),
  backfilled_user_id uuid null references auth.users(id) on delete set null,
  backfilled_at timestamptz null
);

create index if not exists idx_legacy_sixshop_customers_email_lower
  on public.legacy_sixshop_customers (lower(email));

create index if not exists idx_legacy_sixshop_customers_unbackfilled
  on public.legacy_sixshop_customers (email)
  where backfilled_user_id is null;

alter table public.legacy_sixshop_customers enable row level security;

-- 어떤 클라이언트도 직접 select/insert/update 불가. RPC/트리거(security definer)로만 접근.
drop policy if exists legacy_sixshop_customers_no_direct on public.legacy_sixshop_customers;

-- 어드민은 select 가능 (운영 점검용)
drop policy if exists legacy_sixshop_customers_admin_select on public.legacy_sixshop_customers;
create policy legacy_sixshop_customers_admin_select
  on public.legacy_sixshop_customers
  for select
  to authenticated
  using (public.is_admin_user());


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. is_legacy_sixshop_email(email) — anon callable
--    이메일 존재 여부만 boolean으로 반환. PII는 노출하지 않음.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.is_legacy_sixshop_email(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.legacy_sixshop_customers
    where lower(email) = lower(coalesce(p_email, ''))
      and backfilled_user_id is null  -- 이미 backfill된 row는 안내 안 함 (가입 완료 상태)
  );
$$;

grant execute on function public.is_legacy_sixshop_email(text) to anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. legacy_sixshop_backfill_trigger — member_profiles INSERT 시 자동 backfill
--    매칭이 있으면:
--      - member_profiles.phone NULL이면 legacy.phone으로 update
--      - marketing_opt_in false면 legacy.marketing_opt_in_email로 update
--      - member_shipping_addresses에 row 없으면 legacy 배송지 INSERT
--      - member_settlement_accounts에 row 없으면 legacy 계좌 INSERT
--    legacy.backfilled_user_id/backfilled_at 기록
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._legacy_sixshop_backfill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_legacy record;
  v_cipher bytea;
  v_last4 text;
  v_digits text;
begin
  if new.email is null then
    return new;
  end if;

  select *
  into v_legacy
  from public.legacy_sixshop_customers
  where lower(email) = lower(new.email)
    and backfilled_user_id is null
  limit 1;

  if not found then
    return new;
  end if;

  -- 1) member_profiles 자체 backfill (NULL일 때만 덮어쓰기 — 사용자 입력 보호)
  update public.member_profiles
  set
    phone = coalesce(nullif(btrim(phone), ''), v_legacy.phone, phone),
    -- 마케팅 동의는 OR (legacy에서 동의했으면 켜둠. 사용자가 회원가입 폼에서 미체크해도 legacy 우선)
    marketing_opt_in = coalesce(marketing_opt_in, false) or coalesce(v_legacy.marketing_opt_in_email, false),
    updated_at = now()
  where user_id = new.user_id;

  -- 2) 배송지 backfill — 이미 row가 있으면 skip
  if v_legacy.shipping_postal_code is not null
     and v_legacy.shipping_address_line1 is not null
     and not exists (
       select 1 from public.member_shipping_addresses where user_id = new.user_id
     ) then
    insert into public.member_shipping_addresses (
      user_id, label, recipient_name, recipient_phone,
      postal_code, address_line1, address_line2, is_default
    ) values (
      new.user_id,
      '기본 배송지',
      coalesce(v_legacy.name, new.name, ''),
      coalesce(v_legacy.phone, ''),
      v_legacy.shipping_postal_code,
      v_legacy.shipping_address_line1,
      v_legacy.shipping_address_line2,
      true
    );
  end if;

  -- 3) 정산 계좌 backfill — 이미 row가 있으면 skip
  if v_legacy.refund_bank_name is not null
     and v_legacy.refund_account_number_plain is not null
     and not exists (
       select 1 from public.member_settlement_accounts where user_id = new.user_id
     ) then
    v_digits := public.normalize_account_number(v_legacy.refund_account_number_plain);
    if v_digits is not null then
      v_cipher := public.encrypt_account_number(v_digits);
      v_last4 := public.get_account_last4(v_digits);
      insert into public.member_settlement_accounts (
        user_id, bank_name, account_number, account_number_ciphertext, account_number_last4,
        account_holder, is_default
      ) values (
        new.user_id,
        v_legacy.refund_bank_name,
        public.mask_account_number(v_last4),
        v_cipher,
        v_last4,
        coalesce(v_legacy.refund_account_holder, v_legacy.name, ''),
        true
      );
    end if;
  end if;

  -- 4) legacy row를 backfilled로 마킹 (재실행 방지)
  update public.legacy_sixshop_customers
  set backfilled_user_id = new.user_id,
      backfilled_at = now()
  where id = v_legacy.id;

  return new;
end;
$$;

drop trigger if exists trg_legacy_sixshop_backfill on public.member_profiles;
create trigger trg_legacy_sixshop_backfill
  after insert on public.member_profiles
  for each row execute function public._legacy_sixshop_backfill();
