-- TIER 2-2: 개인정보 보호 처리
-- 정산 계좌번호 암호화 저장, 회원 탈퇴 유예/파기 RPC, 약관 동의 이력을 추가한다.

create extension if not exists pgcrypto with schema extensions;

-- Some hosted databases were patched manually before the member-management
-- migration was applied. Keep this privacy migration re-runnable by ensuring
-- the member tables it protects exist first.
create table if not exists public.member_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  name text not null,
  phone text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.member_profiles
  add column if not exists nickname text null,
  add column if not exists marketing_opt_in boolean not null default false;

create index if not exists idx_member_profiles_email_lower
  on public.member_profiles (lower(email));

alter table public.member_profiles enable row level security;

drop policy if exists member_profiles_select_self on public.member_profiles;
drop policy if exists member_profiles_update_self on public.member_profiles;

create policy member_profiles_select_self
  on public.member_profiles
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy member_profiles_update_self
  on public.member_profiles
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create table if not exists public.member_shipping_addresses (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null,
  recipient_name text not null,
  recipient_phone text not null,
  postal_code text not null,
  address_line1 text not null,
  address_line2 text null,
  delivery_memo text null,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.member_settlement_accounts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  bank_name text not null,
  account_number text not null,
  account_holder text not null,
  is_default boolean not null default false,
  is_verified boolean not null default false,
  verified_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_member_shipping_addresses_user_id_created_at
  on public.member_shipping_addresses (user_id, created_at desc);

create unique index if not exists idx_member_shipping_addresses_default
  on public.member_shipping_addresses (user_id)
  where is_default;

create index if not exists idx_member_settlement_accounts_user_id_created_at
  on public.member_settlement_accounts (user_id, created_at desc);

create unique index if not exists idx_member_settlement_accounts_default
  on public.member_settlement_accounts (user_id)
  where is_default;

alter table public.member_shipping_addresses enable row level security;
alter table public.member_settlement_accounts enable row level security;

drop policy if exists member_shipping_addresses_select_self on public.member_shipping_addresses;
drop policy if exists member_shipping_addresses_insert_self on public.member_shipping_addresses;
drop policy if exists member_shipping_addresses_update_self on public.member_shipping_addresses;
drop policy if exists member_shipping_addresses_delete_self on public.member_shipping_addresses;
drop policy if exists member_settlement_accounts_select_self on public.member_settlement_accounts;
drop policy if exists member_settlement_accounts_insert_self on public.member_settlement_accounts;
drop policy if exists member_settlement_accounts_update_self on public.member_settlement_accounts;
drop policy if exists member_settlement_accounts_delete_self on public.member_settlement_accounts;

create policy member_shipping_addresses_select_self
  on public.member_shipping_addresses
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy member_shipping_addresses_insert_self
  on public.member_shipping_addresses
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy member_shipping_addresses_update_self
  on public.member_shipping_addresses
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy member_shipping_addresses_delete_self
  on public.member_shipping_addresses
  for delete
  to authenticated
  using (auth.uid() = user_id);

create policy member_settlement_accounts_select_self
  on public.member_settlement_accounts
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy member_settlement_accounts_insert_self
  on public.member_settlement_accounts
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy member_settlement_accounts_update_self
  on public.member_settlement_accounts
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy member_settlement_accounts_delete_self
  on public.member_settlement_accounts
  for delete
  to authenticated
  using (auth.uid() = user_id);

create or replace function public.touch_member_row_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists member_shipping_addresses_set_updated_at on public.member_shipping_addresses;
create trigger member_shipping_addresses_set_updated_at
before update on public.member_shipping_addresses
for each row
execute function public.touch_member_row_updated_at();

drop trigger if exists member_settlement_accounts_set_updated_at on public.member_settlement_accounts;
create trigger member_settlement_accounts_set_updated_at
before update on public.member_settlement_accounts
for each row
execute function public.touch_member_row_updated_at();

create or replace function public.set_member_default_settlement_account(
  p_account_id bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.member_settlement_accounts
  set is_default = false
  where user_id = auth.uid();

  update public.member_settlement_accounts
  set is_default = true
  where user_id = auth.uid()
    and id = p_account_id;

  if not found then
    raise exception 'Settlement account not found.';
  end if;
end;
$$;

grant execute on function public.set_member_default_settlement_account(bigint) to authenticated;

create or replace function public.get_account_encryption_key()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    nullif(current_setting('app.account_encryption_key', true), ''),
    nullif(current_setting('app.settings.account_encryption_key', true), ''),
    nullif(current_setting('subook.account_encryption_key', true), ''),
    'subook-local-development-account-key'
  );
$$;

create or replace function public.normalize_account_number(p_account_number text)
returns text
language sql
immutable
set search_path = public
as $$
  select nullif(regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g'), '');
$$;

create or replace function public.get_account_last4(p_account_number text)
returns text
language sql
immutable
set search_path = public
as $$
  select right(public.normalize_account_number(p_account_number), 4);
$$;

create or replace function public.mask_account_number(p_account_last4 text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when nullif(btrim(coalesce(p_account_last4, '')), '') is null then null
    else '****' || right(regexp_replace(p_account_last4, '[^0-9]', '', 'g'), 4)
  end;
$$;

create or replace function public.encrypt_account_number(p_account_number text)
returns bytea
language sql
stable
security definer
set search_path = public, extensions
as $$
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
returns text
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if p_account_number_ciphertext is null then
    return null;
  end if;

  return extensions.pgp_sym_decrypt(
    p_account_number_ciphertext,
    public.get_account_encryption_key()
  );
exception
  when others then
    return null;
end;
$$;

create or replace function public.admin_approve_settlements(p_settlement_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  with account_snapshot as (
    select
      st.id,
      account.bank_name,
      account.account_number_ciphertext,
      coalesce(account.account_number_last4, public.get_account_last4(account.account_number)) as account_number_last4,
      account.account_holder
    from public.settlements st
    left join lateral (
      select
        msa.bank_name,
        msa.account_number,
        msa.account_number_ciphertext,
        msa.account_number_last4,
        msa.account_holder
      from public.member_settlement_accounts msa
      where msa.user_id = st.seller_user_id
      order by msa.is_default desc, msa.created_at desc, msa.id desc
      limit 1
    ) account on true
    where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
  )
  update public.settlements st
  set
    status = 'approved',
    approved_at = coalesce(st.approved_at, now()),
    bank_name = coalesce(nullif(btrim(st.bank_name), ''), account_snapshot.bank_name),
    account_number = public.mask_account_number(coalesce(st.account_number_last4, account_snapshot.account_number_last4)),
    account_number_ciphertext = coalesce(st.account_number_ciphertext, account_snapshot.account_number_ciphertext),
    account_number_last4 = coalesce(st.account_number_last4, account_snapshot.account_number_last4),
    account_holder = coalesce(nullif(btrim(st.account_holder), ''), account_snapshot.account_holder)
  from account_snapshot
  where st.id = account_snapshot.id
    and st.status = 'pending';

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'updated_count', v_updated_count);
end;
$$;

create or replace function public.admin_complete_settlements(p_settlement_ids bigint[])
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

  with account_snapshot as (
    select
      st.id,
      coalesce(nullif(btrim(st.bank_name), ''), account.bank_name) as next_bank_name,
      coalesce(st.account_number_ciphertext, account.account_number_ciphertext) as next_account_number_ciphertext,
      coalesce(st.account_number_last4, account.account_number_last4, public.get_account_last4(account.account_number)) as next_account_number_last4,
      coalesce(nullif(btrim(st.account_holder), ''), account.account_holder) as next_account_holder
    from public.settlements st
    left join lateral (
      select
        msa.bank_name,
        msa.account_number,
        msa.account_number_ciphertext,
        msa.account_number_last4,
        msa.account_holder
      from public.member_settlement_accounts msa
      where msa.user_id = st.seller_user_id
      order by msa.is_default desc, msa.created_at desc, msa.id desc
      limit 1
    ) account on true
    where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
      and st.status = 'approved'
  ),
  updated as (
    update public.settlements st
    set
      status = 'completed',
      completed_at = now(),
      bank_name = account_snapshot.next_bank_name,
      account_number = public.mask_account_number(account_snapshot.next_account_number_last4),
      account_number_ciphertext = account_snapshot.next_account_number_ciphertext,
      account_number_last4 = account_snapshot.next_account_number_last4,
      account_holder = account_snapshot.next_account_holder
    from account_snapshot
    where st.id = account_snapshot.id
      and nullif(btrim(coalesce(account_snapshot.next_bank_name, '')), '') is not null
      and account_snapshot.next_account_number_ciphertext is not null
      and nullif(btrim(coalesce(account_snapshot.next_account_holder, '')), '') is not null
    returning st.*
  ),
  settled_books as (
    update public.books b
    set status = 'settled'
    where b.id in (select book_id from updated)
      and b.status <> 'settled'
    returning b.id
  ),
  updated_rows as (
    select
      st.*,
      o.order_number,
      coalesce(oi.title, b.title) as book_title,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as seller_phone,
      mp.email as seller_email
    from updated st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.member_profiles mp
      on mp.user_id = st.seller_user_id
  )
  select jsonb_build_object(
    'success', true,
    'updated_count', (select count(*) from updated_rows),
    'skipped_missing_account_count',
      (
        select count(*)
        from account_snapshot p
        where nullif(btrim(coalesce(p.next_bank_name, '')), '') is null
           or p.next_account_number_ciphertext is null
           or nullif(btrim(coalesce(p.next_account_holder, '')), '') is null
      ),
    'settled_book_count', (select count(*) from settled_books),
    'settlements',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', row_data.id,
              'seller_user_id', row_data.seller_user_id,
              'seller_name', row_data.seller_name,
              'seller_phone', row_data.seller_phone,
              'seller_email', row_data.seller_email,
              'order_id', row_data.order_id,
              'order_number', row_data.order_number,
              'book_id', row_data.book_id,
              'book_title', row_data.book_title,
              'net_amount', row_data.net_amount,
              'bank_name', row_data.bank_name,
              'account_number', public.mask_account_number(coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number))),
              'account_holder', row_data.account_holder,
              'account_last4', coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number)),
              'completed_at', row_data.completed_at
            )
            order by row_data.id
          )
          from updated_rows row_data
        ),
        '[]'::jsonb
      )
  )
  into v_result;

  return v_result;
end;
$$;



create or replace function public.purge_expired_member_personal_data(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_ids uuid[];
  v_purged_count integer := 0;
  v_optional_auth_sets text := '';
begin
  select coalesce(array_agg(user_id), '{}'::uuid[])
  into v_user_ids
  from (
    select user_id
    from public.member_profiles
    where withdrawal_requested_at is not null
      and withdrawal_scheduled_at <= now()
      and personal_data_erased_at is null
    order by withdrawal_scheduled_at asc
    limit greatest(1, least(coalesce(p_limit, 100), 1000))
  ) targets;

  if coalesce(array_length(v_user_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'purged_count', 0);
  end if;

  delete from public.member_shipping_addresses
  where user_id = any(v_user_ids);

  delete from public.member_settlement_accounts
  where user_id = any(v_user_ids);

  delete from public.cart_items
  where user_id = any(v_user_ids);

  update public.pickup_requests
  set
    pickup_recipient_name = '탈퇴회원',
    pickup_recipient_phone = '00000000000',
    pickup_postal_code = '00000',
    pickup_address_line1 = '개인정보 파기',
    pickup_address_line2 = null,
    pickup_memo = null,
    settlement_bank_name = '파기',
    settlement_account_number = null,
    settlement_account_number_ciphertext = null,
    settlement_account_last4 = null,
    settlement_account_holder = '파기',
    updated_at = now()
  where user_id = any(v_user_ids);

  update public.orders
  set
    shipping_recipient_name = '탈퇴회원',
    shipping_recipient_phone = '00000000000',
    shipping_postal_code = '00000',
    shipping_address_line1 = '개인정보 파기',
    shipping_address_line2 = null,
    shipping_memo = null,
    updated_at = now()
  where user_id = any(v_user_ids);

  update public.settlements
  set
    bank_name = null,
    account_number = null,
    account_number_ciphertext = null,
    account_number_last4 = null,
    account_holder = null,
    updated_at = now()
  where seller_user_id = any(v_user_ids);

  if to_regclass('public.notification_logs') is not null then
    update public.notification_logs
    set
      recipient_phone = '00000000000',
      recipient_name = null
    where recipient_user_id = any(v_user_ids);
  end if;

  update public.shipments
  set
    seller_name = '탈퇴회원',
    seller_phone = '00000000000'
  where user_id = any(v_user_ids);

  update public.member_profiles mp
  set
    email = 'withdrawn+' || replace(mp.user_id::text, '-', '') || '@deleted.subook.local',
    name = '탈퇴회원',
    nickname = '탈퇴회원',
    phone = null,
    marketing_opt_in = false,
    email_verified_at = null,
    terms_agreed_at = null,
    privacy_agreed_at = null,
    marketing_agreed_at = null,
    personal_data_erased_at = now(),
    updated_at = now()
  where mp.user_id = any(v_user_ids);

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'auth'
      and table_name = 'users'
      and column_name = 'phone'
  ) then
    v_optional_auth_sets := v_optional_auth_sets || ', phone = null';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'auth'
      and table_name = 'users'
      and column_name = 'encrypted_password'
  ) then
    v_optional_auth_sets := v_optional_auth_sets || ', encrypted_password = null';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'auth'
      and table_name = 'users'
      and column_name = 'deleted_at'
  ) then
    v_optional_auth_sets := v_optional_auth_sets || ', deleted_at = coalesce(deleted_at, now())';
  end if;

  execute '
    update auth.users au
    set
      email = ''withdrawn+'' || replace(au.id::text, ''-'', '''') || ''@deleted.subook.local'',
      raw_user_meta_data = ''{}''::jsonb,
      updated_at = now()
      ' || v_optional_auth_sets || '
    where au.id = any($1)
  ' using v_user_ids;

  get diagnostics v_purged_count = row_count;

  return jsonb_build_object('success', true, 'purged_count', v_purged_count);
end;
$$;

create or replace function public.run_privacy_retention_job()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.purge_expired_member_personal_data(200);
end;
$$;

revoke execute on function public.purge_expired_member_personal_data(integer) from public, anon, authenticated;
revoke execute on function public.run_privacy_retention_job() from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    begin
      perform cron.unschedule('subook-privacy-purge');
    exception
      when others then
        null;
    end;

    perform cron.schedule(
      'subook-privacy-purge',
      '17 18 * * *',
      'select public.run_privacy_retention_job();'
    );
  end if;
exception
  when insufficient_privilege or undefined_function or undefined_table then
    null;
end $$;


create or replace function public.get_my_settlements(
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  with rows as (
    select
      st.*,
      o.order_number,
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.quantity, 1) as quantity,
      b.shipment_id
    from public.settlements st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    where st.seller_user_id = v_user_id
    order by
      case st.status when 'completed' then 1 when 'approved' then 2 else 3 end,
      coalesce(st.completed_at, st.scheduled_date::timestamptz, st.created_at) desc,
      st.id desc
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  ),
  all_my_settlements as (
    select *
    from public.settlements
    where seller_user_id = v_user_id
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', row_data.id,
              'order_id', row_data.order_id,
              'order_number', row_data.order_number,
              'book_id', row_data.book_id,
              'book_title', row_data.book_title,
              'book_option', row_data.book_option,
              'book_count', greatest(1, coalesce(row_data.quantity, 1)),
              'pickup_reference', row_data.shipment_id,
              'sale_amount', row_data.sale_amount,
              'fee_percent', row_data.fee_percent,
              'fee_amount', row_data.fee_amount,
              'net_amount', row_data.net_amount,
              'status', row_data.status,
              'scheduled_date', row_data.scheduled_date,
              'approved_at', row_data.approved_at,
              'completed_at', row_data.completed_at,
              'bank_name', row_data.bank_name,
              'account_number', public.mask_account_number(coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number))),
              'account_holder', row_data.account_holder,
              'account_last4', coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number)),
              'created_at', row_data.created_at
            )
            order by
              case row_data.status when 'completed' then 1 when 'approved' then 2 else 3 end,
              coalesce(row_data.completed_at, row_data.scheduled_date::timestamptz, row_data.created_at) desc,
              row_data.id desc
          )
          from rows row_data
        ),
        '[]'::jsonb
      ),
    'summary',
      jsonb_build_object(
        'current_month_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status = 'completed'
              and completed_at >= date_trunc('month', now())
          ), 0),
        'total_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status = 'completed'
          ), 0),
        'expected_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status in ('pending', 'approved')
          ), 0),
        'pending_count',
          (select count(*) from all_my_settlements where status = 'pending'),
        'approved_count',
          (select count(*) from all_my_settlements where status = 'approved'),
        'completed_count',
          (select count(*) from all_my_settlements where status = 'completed')
      )
  )
  into v_result;

  return v_result;
end;
$$;

alter table public.member_profiles
  add column if not exists terms_agreed_at timestamptz null,
  add column if not exists privacy_agreed_at timestamptz null,
  add column if not exists marketing_agreed_at timestamptz null,
  add column if not exists withdrawal_requested_at timestamptz null,
  add column if not exists withdrawal_scheduled_at timestamptz null,
  add column if not exists personal_data_erased_at timestamptz null;

create index if not exists idx_member_profiles_withdrawal_scheduled
  on public.member_profiles (withdrawal_scheduled_at)
  where withdrawal_requested_at is not null
    and personal_data_erased_at is null;

alter table public.member_settlement_accounts
  add column if not exists account_number_ciphertext bytea null,
  add column if not exists account_number_last4 text null;

alter table public.member_settlement_accounts
  alter column account_number drop not null;

update public.member_settlement_accounts
set
  account_number_ciphertext = coalesce(
    account_number_ciphertext,
    public.encrypt_account_number(account_number)
  ),
  account_number_last4 = coalesce(
    account_number_last4,
    public.get_account_last4(account_number)
  )
where public.normalize_account_number(account_number) is not null;

update public.member_settlement_accounts
set account_number = public.mask_account_number(account_number_last4)
where account_number_ciphertext is not null
  and account_number is not null;

create index if not exists idx_member_settlement_accounts_last4
  on public.member_settlement_accounts (user_id, account_number_last4);

create or replace function public.protect_member_settlement_account_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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

drop trigger if exists member_settlement_accounts_protect_account_number
  on public.member_settlement_accounts;
create trigger member_settlement_accounts_protect_account_number
before insert or update of account_number, account_number_ciphertext, account_number_last4
on public.member_settlement_accounts
for each row
execute function public.protect_member_settlement_account_number();

alter table public.pickup_requests
  add column if not exists settlement_account_number_ciphertext bytea null,
  add column if not exists settlement_account_last4 text null;

alter table public.pickup_requests
  alter column settlement_account_number drop not null;

update public.pickup_requests
set
  settlement_account_number_ciphertext = coalesce(
    settlement_account_number_ciphertext,
    public.encrypt_account_number(settlement_account_number)
  ),
  settlement_account_last4 = coalesce(
    settlement_account_last4,
    public.get_account_last4(settlement_account_number)
  )
where public.normalize_account_number(settlement_account_number) is not null;

update public.pickup_requests
set settlement_account_number = public.mask_account_number(settlement_account_last4)
where settlement_account_number_ciphertext is not null
  and settlement_account_number is not null;

alter table public.settlements
  add column if not exists account_number_ciphertext bytea null,
  add column if not exists account_number_last4 text null;

update public.settlements
set
  account_number_ciphertext = coalesce(
    account_number_ciphertext,
    public.encrypt_account_number(account_number)
  ),
  account_number_last4 = coalesce(
    account_number_last4,
    public.get_account_last4(account_number)
  )
where public.normalize_account_number(account_number) is not null;

update public.settlements
set account_number = public.mask_account_number(account_number_last4)
where account_number_ciphertext is not null
  and account_number is not null;

create or replace function public.list_member_settlement_accounts()
returns table (
  id bigint,
  user_id uuid,
  bank_name text,
  account_holder text,
  account_last4 text,
  account_number_masked text,
  is_default boolean,
  is_verified boolean,
  verified_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    msa.id,
    msa.user_id,
    msa.bank_name,
    msa.account_holder,
    coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number)) as account_last4,
    public.mask_account_number(coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number))) as account_number_masked,
    msa.is_default,
    msa.is_verified,
    msa.verified_at,
    msa.created_at,
    msa.updated_at
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
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_account_id bigint;
  v_account_digits text := public.normalize_account_number(p_account_number);
  v_row public.member_settlement_accounts%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if nullif(btrim(coalesce(p_bank_name, '')), '') is null then
    raise exception 'Bank name is required';
  end if;

  if nullif(btrim(coalesce(p_account_holder, '')), '') is null then
    raise exception 'Account holder is required';
  end if;

  if p_account_id is null and v_account_digits is null then
    raise exception 'Account number is required';
  end if;

  if p_account_id is null then
    insert into public.member_settlement_accounts (
      user_id,
      bank_name,
      account_number,
      account_number_ciphertext,
      account_number_last4,
      account_holder,
      is_default
    )
    values (
      v_user_id,
      btrim(p_bank_name),
      public.mask_account_number(public.get_account_last4(v_account_digits)),
      public.encrypt_account_number(v_account_digits),
      public.get_account_last4(v_account_digits),
      btrim(p_account_holder),
      false
    )
    returning id into v_account_id;
  else
    update public.member_settlement_accounts
    set
      bank_name = btrim(p_bank_name),
      account_number = case
        when v_account_digits is null then account_number
        else public.mask_account_number(public.get_account_last4(v_account_digits))
      end,
      account_number_ciphertext = case
        when v_account_digits is null then account_number_ciphertext
        else public.encrypt_account_number(v_account_digits)
      end,
      account_number_last4 = case
        when v_account_digits is null then account_number_last4
        else public.get_account_last4(v_account_digits)
      end,
      account_holder = btrim(p_account_holder)
    where user_id = v_user_id
      and id = p_account_id
    returning id into v_account_id;

    if v_account_id is null then
      raise exception 'Settlement account not found';
    end if;
  end if;

  if coalesce(p_is_default, false) then
    perform public.set_member_default_settlement_account(v_account_id);
  end if;

  select *
  into v_row
  from public.member_settlement_accounts
  where id = v_account_id
    and user_id = v_user_id;

  return jsonb_build_object(
    'id', v_row.id,
    'user_id', v_row.user_id,
    'bank_name', v_row.bank_name,
    'account_holder', v_row.account_holder,
    'account_last4', coalesce(v_row.account_number_last4, public.get_account_last4(v_row.account_number)),
    'account_number_masked', public.mask_account_number(coalesce(v_row.account_number_last4, public.get_account_last4(v_row.account_number))),
    'is_default', v_row.is_default,
    'is_verified', v_row.is_verified,
    'verified_at', v_row.verified_at,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at
  );
end;
$$;

grant execute on function public.list_member_settlement_accounts() to authenticated;
grant execute on function public.upsert_member_settlement_account(bigint, text, text, text, boolean) to authenticated;

create or replace function public.sync_member_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_email text;
  next_name text;
  next_nickname text;
  next_phone text;
  next_marketing_opt_in boolean := false;
  next_terms_agreed_at timestamptz;
  next_privacy_agreed_at timestamptz;
  next_marketing_agreed_at timestamptz;
  next_email_verified_at timestamptz;
  is_admin_email boolean := false;
begin
  next_email := lower(coalesce(nullif(btrim(new.email), ''), new.id::text || '@oauth.subook.local'));
  next_email_verified_at := new.email_confirmed_at;

  if exists (
    select 1
    from public.member_profiles mp
    where mp.user_id = new.id
      and mp.withdrawal_requested_at is not null
  ) then
    return new;
  end if;

  if next_email_verified_at is null
    and new.raw_app_meta_data is not null
    and new.raw_app_meta_data ->> 'provider' is not null
    and new.raw_app_meta_data ->> 'provider' <> 'email'
  then
    next_email_verified_at := coalesce(new.email_confirmed_at, new.created_at, now());
  end if;

  if to_regclass('public.admin_users') is not null then
    select exists (
      select 1
      from public.admin_users au
      where lower(au.email) = next_email
    )
    into is_admin_email;
  end if;

  if is_admin_email then
    delete from public.member_profiles
    where user_id = new.id
       or lower(email) = next_email;

    return new;
  end if;

  next_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), '');
  next_nickname := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'nickname', '')), '');
  next_phone := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone', '')), '');
  next_marketing_opt_in := case lower(coalesce(new.raw_user_meta_data ->> 'marketing_opt_in', ''))
    when 'true' then true
    when '1' then true
    when 'yes' then true
    when 'on' then true
    else false
  end;
  next_terms_agreed_at := coalesce(
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'terms_agreed_at', '')), '')::timestamptz,
    new.created_at,
    now()
  );
  next_privacy_agreed_at := coalesce(
    nullif(btrim(coalesce(new.raw_user_meta_data ->> 'privacy_agreed_at', '')), '')::timestamptz,
    new.created_at,
    now()
  );
  next_marketing_agreed_at := case
    when next_marketing_opt_in then coalesce(
      nullif(btrim(coalesce(new.raw_user_meta_data ->> 'marketing_agreed_at', '')), '')::timestamptz,
      new.created_at,
      now()
    )
    else null
  end;

  insert into public.member_profiles (
    user_id,
    email,
    name,
    nickname,
    phone,
    marketing_opt_in,
    terms_agreed_at,
    privacy_agreed_at,
    marketing_agreed_at,
    email_verified_at
  )
  values (
    new.id,
    next_email,
    coalesce(next_name, split_part(next_email, '@', 1)),
    coalesce(next_nickname, next_name, split_part(next_email, '@', 1)),
    next_phone,
    next_marketing_opt_in,
    next_terms_agreed_at,
    next_privacy_agreed_at,
    next_marketing_agreed_at,
    next_email_verified_at
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    name = excluded.name,
    nickname = excluded.nickname,
    phone = excluded.phone,
    marketing_opt_in = excluded.marketing_opt_in,
    terms_agreed_at = coalesce(public.member_profiles.terms_agreed_at, excluded.terms_agreed_at),
    privacy_agreed_at = coalesce(public.member_profiles.privacy_agreed_at, excluded.privacy_agreed_at),
    marketing_agreed_at = case
      when excluded.marketing_opt_in then coalesce(public.member_profiles.marketing_agreed_at, excluded.marketing_agreed_at)
      else null
    end,
    email_verified_at = case
      when public.member_profiles.email = excluded.email
        then coalesce(public.member_profiles.email_verified_at, excluded.email_verified_at)
      else excluded.email_verified_at
    end,
    updated_at = now();

  begin
    if next_phone is not null and to_regclass('public.shipments') is not null then
      update public.shipments s
      set user_id = new.id
      where s.user_id is null
        and s.seller_name = coalesce(next_name, split_part(next_email, '@', 1))
        and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
          regexp_replace(next_phone, '[^0-9]', '', 'g');
    end if;
  exception
    when undefined_table or undefined_column then
      null;
  end;

  return new;
end;
$$;

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
    mp.withdrawal_requested_at,
    mp.withdrawal_scheduled_at,
    mp.personal_data_erased_at
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

grant execute on function public.get_current_auth_account_role() to authenticated;

create or replace function public.request_member_withdrawal()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz := now();
  v_scheduled_at timestamptz := now() + interval '30 days';
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  update public.member_profiles
  set
    withdrawal_requested_at = coalesce(withdrawal_requested_at, v_requested_at),
    withdrawal_scheduled_at = coalesce(withdrawal_scheduled_at, v_scheduled_at),
    marketing_opt_in = false,
    updated_at = now()
  where user_id = v_user_id
    and personal_data_erased_at is null;

  if not found then
    raise exception 'Member profile not found';
  end if;

  delete from public.cart_items
  where user_id = v_user_id;

  return jsonb_build_object(
    'success', true,
    'withdrawal_requested_at', v_requested_at,
    'withdrawal_scheduled_at', v_scheduled_at
  );
end;
$$;

grant execute on function public.request_member_withdrawal() to authenticated;

drop function if exists public.submit_pickup_request(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb
);

create or replace function public.submit_pickup_request(
  p_pickup_recipient_name text,
  p_pickup_recipient_phone text,
  p_pickup_postal_code text,
  p_pickup_address_line1 text,
  p_pickup_address_line2 text,
  p_pickup_memo text,
  p_settlement_bank_name text,
  p_settlement_account_number text,
  p_settlement_account_holder text,
  p_items jsonb,
  p_settlement_account_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_request_id bigint;
  v_request_number text;
  v_item jsonb;
  v_item_count integer;
  v_account record;
  v_bank_name text;
  v_account_holder text;
  v_account_digits text;
  v_account_ciphertext bytea;
  v_account_last4 text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  v_item_count := jsonb_array_length(coalesce(p_items, '[]'::jsonb));
  if v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;

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

  v_request_number := public.generate_pickup_request_number();

  insert into public.pickup_requests (
    user_id, request_number, status,
    pickup_recipient_name, pickup_recipient_phone,
    pickup_postal_code, pickup_address_line1, pickup_address_line2, pickup_memo,
    settlement_bank_name, settlement_account_number, settlement_account_number_ciphertext,
    settlement_account_last4, settlement_account_holder,
    policy_agreed_at, item_count
  ) values (
    v_user_id, v_request_number, 'pending',
    p_pickup_recipient_name, p_pickup_recipient_phone,
    p_pickup_postal_code, p_pickup_address_line1, p_pickup_address_line2, p_pickup_memo,
    v_bank_name, public.mask_account_number(v_account_last4), v_account_ciphertext,
    v_account_last4, v_account_holder,
    now(), v_item_count
  )
  returning id into v_request_id;

  for v_item in select * from jsonb_array_elements(p_items)
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
    'item_count', v_item_count,
    'settlement_account_last4', v_account_last4
  );
end;
$$;

grant execute on function public.submit_pickup_request(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb,
  bigint
) to authenticated;

create or replace function public.create_settlements_for_order(p_order_id bigint)
returns integer
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
  select *
  into v_order
  from public.orders
  where id = p_order_id
    and status = 'confirmed'
    and confirmed_at is not null;

  if not found then
    return 0;
  end if;

  for v_item in
    select
      oi.id as order_item_id,
      oi.book_id,
      oi.quantity,
      oi.unit_price,
      oi.total_price,
      b.shipment_id,
      s.user_id as seller_user_id,
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
    v_sale_amount := greatest(0, coalesce(v_item.total_price, v_item.unit_price * greatest(1, coalesce(v_item.quantity, 1)), 0));
    v_unit_price := greatest(
      0,
      coalesce(
        v_item.unit_price,
        case
          when coalesce(v_item.quantity, 0) > 0 then floor(v_sale_amount::numeric / v_item.quantity)::integer
          else v_sale_amount
        end,
        0
      )
    );
    v_fee_percent := public.calculate_settlement_fee_percent(v_unit_price, v_item.pickup_date);
    v_fee_amount := floor(v_sale_amount * (v_fee_percent / 100))::integer;

    insert into public.settlements (
      seller_user_id,
      order_id,
      order_item_id,
      book_id,
      sale_amount,
      fee_percent,
      fee_amount,
      net_amount,
      status,
      scheduled_date,
      bank_name,
      account_number,
      account_number_ciphertext,
      account_number_last4,
      account_holder
    )
    values (
      v_item.seller_user_id,
      p_order_id,
      v_item.order_item_id,
      v_item.book_id,
      v_sale_amount,
      v_fee_percent,
      v_fee_amount,
      greatest(0, v_sale_amount - v_fee_amount),
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

  return v_inserted_count;
end;
$$;

create or replace function public.list_admin_settlements(
  p_statuses text[] default null,
  p_search text default null,
  p_from_date date default null,
  p_to_date date default null,
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

  with filtered as (
    select
      st.*,
      o.order_number,
      o.confirmed_at,
      oi.quantity,
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.condition_grade, b.condition_grade) as condition_grade,
      b.shipment_id,
      sh.seller_name as shipment_seller_name,
      sh.seller_phone as shipment_seller_phone,
      mp.email as seller_email,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as seller_phone
    from public.settlements st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.member_profiles mp
      on mp.user_id = st.seller_user_id
    where
      (coalesce(cardinality(p_statuses), 0) = 0 or st.status = any(p_statuses))
      and (p_from_date is null or st.scheduled_date >= p_from_date)
      and (p_to_date is null or st.scheduled_date <= p_to_date)
      and (
        nullif(btrim(coalesce(p_search, '')), '') is null
        or o.order_number ilike '%' || btrim(p_search) || '%'
        or coalesce(oi.title, b.title) ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.name, sh.seller_name, '') ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.email, '') ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.phone, sh.seller_phone, '') ilike '%' || btrim(p_search) || '%'
      )
  ),
  page_rows as (
    select *
    from filtered
    order by
      case status when 'pending' then 1 when 'approved' then 2 else 3 end,
      scheduled_date asc,
      id desc
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 100), 500))
  )
  select jsonb_build_object(
    'rows',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', row_data.id,
            'seller_user_id', row_data.seller_user_id,
            'seller_name', coalesce(row_data.seller_name, '판매자 미연결'),
            'seller_email', row_data.seller_email,
            'seller_phone', row_data.seller_phone,
            'order_id', row_data.order_id,
            'order_number', row_data.order_number,
            'order_item_id', row_data.order_item_id,
            'book_id', row_data.book_id,
            'book_title', row_data.book_title,
            'book_option', row_data.book_option,
            'condition_grade', row_data.condition_grade,
            'shipment_id', row_data.shipment_id,
            'sale_amount', row_data.sale_amount,
            'fee_percent', row_data.fee_percent,
            'fee_amount', row_data.fee_amount,
            'net_amount', row_data.net_amount,
            'status', row_data.status,
            'scheduled_date', row_data.scheduled_date,
            'approved_at', row_data.approved_at,
            'completed_at', row_data.completed_at,
            'bank_name', row_data.bank_name,
            'account_number', public.mask_account_number(coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number))),
            'account_holder', row_data.account_holder,
            'account_last4', coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number)),
            'confirmed_at', row_data.confirmed_at,
            'created_at', row_data.created_at,
            'updated_at', row_data.updated_at
          )
          order by
            case row_data.status when 'pending' then 1 when 'approved' then 2 else 3 end,
            row_data.scheduled_date asc,
            row_data.id desc
        )
        from page_rows row_data
      ),
      '[]'::jsonb
    ),
    'total_count', (select count(*) from filtered),
    'summary',
    jsonb_build_object(
      'pending_count', (select count(*) from filtered where status = 'pending'),
      'approved_count', (select count(*) from filtered where status = 'approved'),
      'completed_count', (select count(*) from filtered where status = 'completed'),
      'pending_amount', coalesce((select sum(net_amount) from filtered where status = 'pending'), 0),
      'approved_amount', coalesce((select sum(net_amount) from filtered where status = 'approved'), 0),
      'completed_amount', coalesce((select sum(net_amount) from filtered where status = 'completed'), 0),
      'due_pending_count', (select count(*) from filtered where status = 'pending' and scheduled_date <= current_date),
      'due_pending_amount', coalesce((select sum(net_amount) from filtered where status = 'pending' and scheduled_date <= current_date), 0)
    )
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function public.create_settlements_for_order(bigint) to authenticated;
grant execute on function public.list_admin_settlements(text[], text, date, date, integer, integer) to authenticated;
grant execute on function public.admin_approve_settlements(bigint[]) to authenticated;
grant execute on function public.admin_complete_settlements(bigint[]) to authenticated;
grant execute on function public.get_my_settlements(integer, integer) to authenticated;
