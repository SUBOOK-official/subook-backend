-- DRIFT REPAIR: 2026041206(개인정보보호/정산계좌 암호화/탈퇴) + 2026041303(reviews)의
-- prod 미적용 객체만 surgical 복구. (2026-05-04 '실행 없이 applied로 back-mark'된 후유증)
--
-- 정식 드리프트 진단(마이그레이션 121개 vs prod 실제 스키마) 결과 누락:
--   함수11(암호화 헬퍼5 + protect함수 + 파기2 + 정산계좌RPC2 + 탈퇴) + reviews테이블 + 트리거2
-- ⚠️ 두 마이그레이션을 통째로 재실행하면 get_current_auth_account_role/submit_pickup_request/
--    정산 함수 등 '이후 마이그레이션이 더 최신으로 바꾼' 것들을 덮으므로, **누락분만** 재생성한다.
-- 전부 멱등(IF NOT EXISTS / CREATE OR REPLACE).

-- ── 0) 확장 ──
create extension if not exists pgcrypto with schema extensions;

-- ── 1) 암호화 헬퍼 (SQL 함수라 의존 순서 중요: normalize→last4→mask→encrypt→decrypt) ──
create or replace function public.normalize_account_number(p_account_number text)
returns text language sql immutable set search_path = public as $$
  select nullif(regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g'), '');
$$;

create or replace function public.get_account_last4(p_account_number text)
returns text language sql immutable set search_path = public as $$
  select right(public.normalize_account_number(p_account_number), 4);
$$;

create or replace function public.mask_account_number(p_account_last4 text)
returns text language sql immutable set search_path = public as $$
  select case
    when nullif(btrim(coalesce(p_account_last4, '')), '') is null then null
    else '****' || right(regexp_replace(p_account_last4, '[^0-9]', '', 'g'), 4)
  end;
$$;

create or replace function public.encrypt_account_number(p_account_number text)
returns bytea language sql stable security definer set search_path = public, extensions as $$
  select case
    when public.normalize_account_number(p_account_number) is null then null
    else extensions.pgp_sym_encrypt(
      public.normalize_account_number(p_account_number),
      public.get_account_encryption_key(),
      'cipher-algo=aes256, compress-algo=0'
    )
  end;
$$;

create or replace function public.decrypt_account_number(p_account_number_ciphertext bytea)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if p_account_number_ciphertext is null then
    return null;
  end if;
  return extensions.pgp_sym_decrypt(p_account_number_ciphertext, public.get_account_encryption_key());
exception
  when others then
    return null;
end;
$$;

-- ── 2) member_settlement_accounts: 암호화 컬럼 + 기존 평문 암호화(데이터 보정) ──
alter table public.member_settlement_accounts
  add column if not exists account_number_ciphertext bytea null,
  add column if not exists account_number_last4 text null;
alter table public.member_settlement_accounts
  alter column account_number drop not null;

update public.member_settlement_accounts
set
  account_number_ciphertext = coalesce(account_number_ciphertext, public.encrypt_account_number(account_number)),
  account_number_last4 = coalesce(account_number_last4, public.get_account_last4(account_number))
where public.normalize_account_number(account_number) is not null;

update public.member_settlement_accounts
set account_number = public.mask_account_number(account_number_last4)
where account_number_ciphertext is not null and account_number is not null;

create index if not exists idx_member_settlement_accounts_last4
  on public.member_settlement_accounts (user_id, account_number_last4);

-- ── 3) 정산계좌 평문 보호 트리거 (데이터 보정 이후 생성) ──
create or replace function public.protect_member_settlement_account_number()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_digits text;
begin
  v_digits := public.normalize_account_number(new.account_number);
  if v_digits is not null and left(coalesce(new.account_number, ''), 4) <> '****' then
    new.account_number_ciphertext := public.encrypt_account_number(v_digits);
    new.account_number_last4 := public.get_account_last4(v_digits);
    new.account_number := public.mask_account_number(new.account_number_last4);
  elsif new.account_number_ciphertext is not null then
    new.account_number_last4 := coalesce(new.account_number_last4, public.get_account_last4(public.decrypt_account_number(new.account_number_ciphertext)));
    new.account_number := public.mask_account_number(new.account_number_last4);
  end if;
  return new;
end;
$$;

drop trigger if exists member_settlement_accounts_protect_account_number on public.member_settlement_accounts;
create trigger member_settlement_accounts_protect_account_number
before insert or update of account_number, account_number_ciphertext, account_number_last4
on public.member_settlement_accounts
for each row execute function public.protect_member_settlement_account_number();

-- ── 4) pickup_requests / settlements: 암호화 컬럼 + 기존 평문 암호화 ──
alter table public.pickup_requests
  add column if not exists settlement_account_number_ciphertext bytea null,
  add column if not exists settlement_account_last4 text null;
alter table public.pickup_requests
  alter column settlement_account_number drop not null;

update public.pickup_requests
set
  settlement_account_number_ciphertext = coalesce(settlement_account_number_ciphertext, public.encrypt_account_number(settlement_account_number)),
  settlement_account_last4 = coalesce(settlement_account_last4, public.get_account_last4(settlement_account_number))
where public.normalize_account_number(settlement_account_number) is not null;
update public.pickup_requests
set settlement_account_number = public.mask_account_number(settlement_account_last4)
where settlement_account_number_ciphertext is not null and settlement_account_number is not null;

alter table public.settlements
  add column if not exists account_number_ciphertext bytea null,
  add column if not exists account_number_last4 text null;

update public.settlements
set
  account_number_ciphertext = coalesce(account_number_ciphertext, public.encrypt_account_number(account_number)),
  account_number_last4 = coalesce(account_number_last4, public.get_account_last4(account_number))
where public.normalize_account_number(account_number) is not null;
update public.settlements
set account_number = public.mask_account_number(account_number_last4)
where account_number_ciphertext is not null and account_number is not null;

-- ── 5) 정산계좌 회원 RPC (list / upsert) + grant ──
create or replace function public.list_member_settlement_accounts()
returns table (
  id bigint, user_id uuid, bank_name text, account_holder text, account_last4 text,
  account_number_masked text, is_default boolean, is_verified boolean,
  verified_at timestamptz, created_at timestamptz, updated_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select
    msa.id, msa.user_id, msa.bank_name, msa.account_holder,
    coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number)) as account_last4,
    public.mask_account_number(coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number))) as account_number_masked,
    msa.is_default, msa.is_verified, msa.verified_at, msa.created_at, msa.updated_at
  from public.member_settlement_accounts msa
  where msa.user_id = auth.uid()
  order by msa.is_default desc, msa.created_at desc, msa.id desc;
$$;

create or replace function public.upsert_member_settlement_account(
  p_account_id bigint default null,
  p_bank_name text default null,
  p_account_number text default null,
  p_account_holder text default null,
  p_is_default boolean default false
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_account_id bigint;
  v_account_digits text := public.normalize_account_number(p_account_number);
  v_row public.member_settlement_accounts%rowtype;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if nullif(btrim(coalesce(p_bank_name, '')), '') is null then raise exception 'Bank name is required'; end if;
  if nullif(btrim(coalesce(p_account_holder, '')), '') is null then raise exception 'Account holder is required'; end if;
  if p_account_id is null and v_account_digits is null then raise exception 'Account number is required'; end if;

  if p_account_id is null then
    insert into public.member_settlement_accounts (
      user_id, bank_name, account_number, account_number_ciphertext, account_number_last4, account_holder, is_default
    ) values (
      v_user_id, btrim(p_bank_name),
      public.mask_account_number(public.get_account_last4(v_account_digits)),
      public.encrypt_account_number(v_account_digits),
      public.get_account_last4(v_account_digits),
      btrim(p_account_holder), false
    ) returning id into v_account_id;
  else
    update public.member_settlement_accounts
    set
      bank_name = btrim(p_bank_name),
      account_number = case when v_account_digits is null then account_number else public.mask_account_number(public.get_account_last4(v_account_digits)) end,
      account_number_ciphertext = case when v_account_digits is null then account_number_ciphertext else public.encrypt_account_number(v_account_digits) end,
      account_number_last4 = case when v_account_digits is null then account_number_last4 else public.get_account_last4(v_account_digits) end,
      account_holder = btrim(p_account_holder)
    where user_id = v_user_id and id = p_account_id
    returning id into v_account_id;
    if v_account_id is null then raise exception 'Settlement account not found'; end if;
  end if;

  if coalesce(p_is_default, false) then
    perform public.set_member_default_settlement_account(v_account_id);
  end if;

  select * into v_row from public.member_settlement_accounts where id = v_account_id and user_id = v_user_id;

  return jsonb_build_object(
    'id', v_row.id, 'user_id', v_row.user_id, 'bank_name', v_row.bank_name, 'account_holder', v_row.account_holder,
    'account_last4', coalesce(v_row.account_number_last4, public.get_account_last4(v_row.account_number)),
    'account_number_masked', public.mask_account_number(coalesce(v_row.account_number_last4, public.get_account_last4(v_row.account_number))),
    'is_default', v_row.is_default, 'is_verified', v_row.is_verified, 'verified_at', v_row.verified_at,
    'created_at', v_row.created_at, 'updated_at', v_row.updated_at
  );
end;
$$;

grant execute on function public.list_member_settlement_accounts() to authenticated;
grant execute on function public.upsert_member_settlement_account(bigint, text, text, text, boolean) to authenticated;

-- ── 6) 회원 탈퇴 RPC ──
alter table public.member_profiles
  add column if not exists terms_agreed_at timestamptz null,
  add column if not exists privacy_agreed_at timestamptz null,
  add column if not exists marketing_agreed_at timestamptz null,
  add column if not exists withdrawal_requested_at timestamptz null,
  add column if not exists withdrawal_scheduled_at timestamptz null,
  add column if not exists personal_data_erased_at timestamptz null;

create index if not exists idx_member_profiles_withdrawal_scheduled
  on public.member_profiles (withdrawal_scheduled_at)
  where withdrawal_requested_at is not null and personal_data_erased_at is null;

create or replace function public.request_member_withdrawal()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz := now();
  v_scheduled_at timestamptz := now() + interval '30 days';
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  update public.member_profiles
  set
    withdrawal_requested_at = coalesce(withdrawal_requested_at, v_requested_at),
    withdrawal_scheduled_at = coalesce(withdrawal_scheduled_at, v_scheduled_at),
    marketing_opt_in = false, updated_at = now()
  where user_id = v_user_id and personal_data_erased_at is null;
  if not found then raise exception 'Member profile not found'; end if;
  delete from public.cart_items where user_id = v_user_id;
  return jsonb_build_object('success', true, 'withdrawal_requested_at', v_requested_at, 'withdrawal_scheduled_at', v_scheduled_at);
end;
$$;

grant execute on function public.request_member_withdrawal() to authenticated;

-- ── 7) 개인정보 파기 잡 (관리자/크론 전용 — public 권한 회수) ──
create or replace function public.purge_expired_member_personal_data(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_ids uuid[];
  v_purged_count integer := 0;
  v_optional_auth_sets text := '';
begin
  select coalesce(array_agg(user_id), '{}'::uuid[]) into v_user_ids
  from (
    select user_id from public.member_profiles
    where withdrawal_requested_at is not null and withdrawal_scheduled_at <= now() and personal_data_erased_at is null
    order by withdrawal_scheduled_at asc
    limit greatest(1, least(coalesce(p_limit, 100), 1000))
  ) targets;

  if coalesce(array_length(v_user_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'purged_count', 0);
  end if;

  delete from public.member_shipping_addresses where user_id = any(v_user_ids);
  delete from public.member_settlement_accounts where user_id = any(v_user_ids);
  delete from public.cart_items where user_id = any(v_user_ids);

  update public.pickup_requests set
    pickup_recipient_name = '탈퇴회원', pickup_recipient_phone = '00000000000',
    pickup_postal_code = '00000', pickup_address_line1 = '개인정보 파기', pickup_address_line2 = null, pickup_memo = null,
    settlement_bank_name = '파기', settlement_account_number = null, settlement_account_number_ciphertext = null,
    settlement_account_last4 = null, settlement_account_holder = '파기', updated_at = now()
  where user_id = any(v_user_ids);

  update public.orders set
    shipping_recipient_name = '탈퇴회원', shipping_recipient_phone = '00000000000',
    shipping_postal_code = '00000', shipping_address_line1 = '개인정보 파기', shipping_address_line2 = null, shipping_memo = null, updated_at = now()
  where user_id = any(v_user_ids);

  update public.settlements set
    bank_name = null, account_number = null, account_number_ciphertext = null, account_number_last4 = null, account_holder = null, updated_at = now()
  where seller_user_id = any(v_user_ids);

  if to_regclass('public.notification_logs') is not null then
    update public.notification_logs set recipient_phone = '00000000000', recipient_name = null where recipient_user_id = any(v_user_ids);
  end if;

  update public.shipments set seller_name = '탈퇴회원', seller_phone = '00000000000' where user_id = any(v_user_ids);

  update public.member_profiles mp set
    email = 'withdrawn+' || replace(mp.user_id::text, '-', '') || '@deleted.subook.local',
    name = '탈퇴회원', nickname = '탈퇴회원', phone = null, marketing_opt_in = false,
    email_verified_at = null, terms_agreed_at = null, privacy_agreed_at = null, marketing_agreed_at = null,
    personal_data_erased_at = now(), updated_at = now()
  where mp.user_id = any(v_user_ids);

  if exists (select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='phone') then
    v_optional_auth_sets := v_optional_auth_sets || ', phone = null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='encrypted_password') then
    v_optional_auth_sets := v_optional_auth_sets || ', encrypted_password = null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='deleted_at') then
    v_optional_auth_sets := v_optional_auth_sets || ', deleted_at = coalesce(deleted_at, now())';
  end if;

  execute '
    update auth.users au set
      email = ''withdrawn+'' || replace(au.id::text, ''-'', '''') || ''@deleted.subook.local'',
      raw_user_meta_data = ''{}''::jsonb, updated_at = now() ' || v_optional_auth_sets || '
    where au.id = any($1)' using v_user_ids;

  get diagnostics v_purged_count = row_count;
  return jsonb_build_object('success', true, 'purged_count', v_purged_count);
end;
$$;

create or replace function public.run_privacy_retention_job()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return public.purge_expired_member_personal_data(200);
end;
$$;

revoke execute on function public.purge_expired_member_personal_data(integer) from public, anon, authenticated;
revoke execute on function public.run_privacy_retention_job() from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    begin perform cron.unschedule('subook-privacy-purge'); exception when others then null; end;
    perform cron.schedule('subook-privacy-purge', '17 18 * * *', 'select public.run_privacy_retention_job();');
  end if;
exception when insufficient_privilege or undefined_function or undefined_table then null;
end $$;

-- ── 8) reviews 테이블 + 트리거 (2026041303 누락분; 스토리지 버킷은 리뷰 기능 배선 시 별도) ──
create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  order_id bigint not null references public.orders(id) on delete cascade,
  order_item_id bigint not null references public.order_items(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  author_name text not null,
  rating integer not null check (rating between 1 and 5),
  content text not null check (char_length(btrim(coalesce(content, ''))) between 1 and 200),
  photo_urls text[] not null default '{}'::text[] check (coalesce(cardinality(photo_urls), 0) <= 3),
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_item_id)
);

create index if not exists idx_reviews_product_created_at on public.reviews (product_id, created_at desc) where is_hidden = false;
create index if not exists idx_reviews_user_created_at on public.reviews (user_id, created_at desc);

alter table public.reviews enable row level security;

drop policy if exists "reviews_select_public_visible" on public.reviews;
create policy "reviews_select_public_visible" on public.reviews
  for select to anon, authenticated
  using (not is_hidden or user_id = auth.uid() or public.is_admin_user());

drop policy if exists "reviews_admin_all" on public.reviews;
create policy "reviews_admin_all" on public.reviews
  for all to authenticated
  using (public.is_admin_user()) with check (public.is_admin_user());

create or replace function public.touch_reviews_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists reviews_set_updated_at on public.reviews;
create trigger reviews_set_updated_at
before update on public.reviews
for each row execute function public.touch_reviews_updated_at();

-- ── 9) PostgREST 스키마 캐시 리로드 (pooler 경유 시 미도달 가능 → 대시보드 Reload 권장) ──
notify pgrst, 'reload schema';
