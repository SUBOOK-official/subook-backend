import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { readFileSync } from 'node:fs';

export const uid = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
export const migration = (name) => readFileSync(new URL(`../../supabase/migrations/${name}.sql`, import.meta.url), 'utf8');
export async function makeIdentityDb({seedVerifiedDuplicates=false}={}) {
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(`
    create role anon; create role authenticated; create role service_role; create schema auth; create schema extensions;
    create extension pgcrypto with schema extensions;
    create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.uid',true),'')::uuid $$;
    create function auth.role() returns text language sql as $$ select coalesce(nullif(current_setting('test.role',true),''),'authenticated') $$;
    create function auth.jwt() returns jsonb language sql as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}'::jsonb) $$;
    grant usage on schema auth to anon,authenticated,service_role;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,phone text unique,phone_confirmed_at timestamptz,
      encrypted_password text,raw_app_meta_data jsonb,raw_user_meta_data jsonb default '{}',created_at timestamptz default now(),last_sign_in_at timestamptz default now(),deleted_at timestamptz);
    create table auth.identities(user_id uuid references auth.users(id),provider text);
    create table public.member_profiles(user_id uuid primary key references auth.users(id),email text unique,name text,nickname text,phone text,
      marketing_opt_in boolean default false,marketing_agreed_at timestamptz,terms_agreed_at timestamptz,privacy_agreed_at timestamptz,
      email_verified_at timestamptz,withdrawal_requested_at timestamptz,withdrawal_scheduled_at timestamptz,personal_data_erased_at timestamptz,is_blocked boolean default false,
      block_reason text,updated_at timestamptz,verified_phone text,phone_verified_at timestamptz);
    create table public.admin_users(email text);
    create function public.is_admin_user() returns boolean language sql as $$ select false $$;
    create function public.assert_member_not_blocked() returns void language plpgsql as $$ begin return; end $$;
    create table public.coupons(id bigint generated always as identity primary key,title text,description text,discount_type text,discount_value integer,
      min_order_amount integer,valid_days integer,valid_until timestamptz,valid_from timestamptz,usage_limit_per_user integer,issuance_type text,
      campaign_key text unique,is_active boolean default true,issued_count integer default 0,total_quantity integer,issue_on_signup boolean default false);
    create table public.member_coupons(id bigint generated always as identity primary key,coupon_id bigint references public.coupons(id),
      user_id uuid references auth.users(id),issued_at timestamptz default now(),expires_at timestamptz,used_at timestamptz,used_order_id bigint,
      status text default 'available' check(status in ('available','used','expired')),unique(coupon_id,user_id));
    create function public.compute_coupon_member_expiry(integer,timestamptz) returns timestamptz language sql as $$ select coalesce(now()+make_interval(days=>$1),$2) $$;
    create table public.phone_verification_codes(id bigint generated always as identity primary key,user_id uuid references auth.users(id),
      phone text,code_hash text,expires_at timestamptz,attempt_count integer default 0,verified_at timestamptz,created_at timestamptz default now());
    create table public.orders(id bigint generated always as identity primary key,user_id uuid,payment_status text default 'paid',total_amount integer);
    create table public.order_items(id bigint primary key,order_id bigint);
    create table public.pg_checkout_sessions(id bigint generated always as identity primary key,user_id uuid,status text,created_at timestamptz default now());
    create table public.shipments(id bigint generated always as identity primary key,user_id uuid,seller_name text,seller_phone text);
    create table public.pickup_requests(id bigint generated always as identity primary key,user_id uuid);
    create table public.pickup_items(id bigint primary key,pickup_request_id bigint);
    create table public.settlements(id bigint generated always as identity primary key,seller_user_id uuid,net_amount integer,bank_name text,account_number text);
    create table public.point_lots(id bigint generated always as identity primary key,user_id uuid,remaining integer,voided_at timestamptz,expires_at timestamptz);
    create table public.point_transactions(id bigint generated always as identity primary key,user_id uuid,amount integer,lot_id bigint);
    create table public.member_shipping_addresses(id bigint generated always as identity primary key,user_id uuid,is_default boolean,address text);
    create unique index shipping_default on public.member_shipping_addresses(user_id) where is_default;
    create table public.member_settlement_accounts(id bigint generated always as identity primary key,user_id uuid,is_default boolean,account_number text);
    create unique index settlement_default on public.member_settlement_accounts(user_id) where is_default;
    create table public.cart_items(id bigint generated always as identity primary key,user_id uuid,book_id bigint,quantity integer,unique(user_id,book_id));
    create table public.wishlist_items(id bigint generated always as identity primary key,user_id uuid,product_id bigint,unique(user_id,product_id));
    create table public.restock_keyword_subscriptions(id bigint generated always as identity primary key,user_id uuid,keyword_norm text,unique(user_id,keyword_norm));
    create table public.restock_notifications(id bigint generated always as identity primary key,user_id uuid,product_id bigint,notified_at timestamptz);
    create unique index restock_pending on public.restock_notifications(user_id,product_id) where notified_at is null;
    create table public.retention_experiment_members(experiment_id uuid,user_id uuid,arm text,primary key(experiment_id,user_id));
    create table public.member_notes(id bigint generated always as identity primary key,member_user_id uuid,author_user_id uuid);
    create table public.notification_logs(id bigint generated always as identity primary key,recipient_user_id uuid);
    create table public.legacy_sixshop_customers(id bigint generated always as identity primary key,backfilled_user_id uuid);
  `);
  for (const table of ['reviews','legacy_reviews','member_notifications','event_subscriptions']) {
    await db.exec(`create table public.${table}(id bigint generated always as identity primary key,user_id uuid)`);
  }
  await db.exec(migration('20260724053221_harden_member_profile_sync'));
  await db.exec(migration('20260525135915_complete_signup_with_name_phone'));
  await db.exec('create trigger sync_profile after insert or update on auth.users for each row execute function public.sync_member_profile_from_auth()');
  await db.exec(migration('20261001042015_signup_referral_coupons'));
  await db.exec(migration('20261001053820_single_use_signup_referrals'));
  if(seedVerifiedDuplicates){
    for(const n of [90,91,92]){
      await db.query('insert into auth.users(id,email) values($1,$2)',[uid(n),`legacy${n}@example.invalid`]);
      await db.query('update member_profiles set phone=$2,verified_phone=$3,phone_verified_at=now() where user_id=$1',
        [uid(n),n===92?'01099999998':'01099999999',n===91?'+821099999999':n===92?'01099999998':'01099999999']);
    }
  }
  await db.exec(migration('20261001054602_phone_member_identity'));
  await db.exec(migration('20261001060422_phone_identity_enforcement'));
  await db.exec(migration('20261001060424_member_selected_account_merge'));
  await db.exec(migration('20261001060942_phone_verified_referral_rewards'));
  await db.exec(`create trigger issue_signup_initial after insert on public.member_profiles for each row execute function public.issue_signup_coupons_for_new_member();
    update public.member_identity_policy set enabled=true,phone_signup_enabled=true,merge_enabled=true,activated_at=now()-interval '1 second';`);
  return db;
}
