// 읽기 전용: 개인정보/인증키를 출력하지 않고 번호 인증 전환의 영향도를 집계한다.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';

const env = { ...process.env, ...parseEnv(readFileSync('.env', 'utf8')), ...parseEnv(readFileSync('.env.local', 'utf8')) };
const ref = env.SUPABASE_PROJECT_REF;
if (new URL(env.VITE_SUPABASE_URL).hostname.split('.')[0] !== ref || readFileSync('backend/supabase/.temp/project-ref', 'utf8').trim() !== ref) throw Error('Project mismatch');
async function query(sql) {
  const response = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql, read_only: true }), signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw Error(`Read-only audit failed: ${response.status}`);
  return response.json();
}
const counts = await query(`with phones as (select user_id, regexp_replace(coalesce(phone,''),'[^0-9]','','g') as phone,
  verified_phone, phone_verified_at from public.member_profiles), duplicate_groups as (
  select phone,count(*) as members from phones where phone ~ '^01[016789][0-9]{7,8}$' group by phone having count(*)>1)
  select (select count(*) from phones) as members,
    (select count(*) from phones where phone='') as missing_phone,
    (select count(*) from phones where phone<>'' and phone !~ '^01[016789][0-9]{7,8}$') as invalid_phone,
    (select count(*) from phones where phone_verified_at is not null and verified_phone is not null) as verified_members,
    (select count(*) from duplicate_groups) as duplicate_phone_groups,
    (select sum(members) from duplicate_groups) as members_in_duplicate_groups,
    (select count(*) from public.member_referral_signups where rewarded_at is not null) as completed_referrals`);
const relations = await query(`select n.nspname as schema,t.relname as table_name,a.attname as column_name,
  fn.nspname as foreign_schema,ft.relname as foreign_table,fa.attname as foreign_column,c.conname
  from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
  join pg_class ft on ft.oid=c.confrelid join pg_namespace fn on fn.oid=ft.relnamespace
  join pg_attribute a on a.attrelid=t.oid and a.attnum=any(c.conkey)
  join pg_attribute fa on fa.attrelid=ft.oid and fa.attnum=any(c.confkey)
  where c.contype='f' and n.nspname='public' and (c.confrelid='auth.users'::regclass or ft.relname='member_profiles')
  order by t.relname,a.attname`);
const functions = await query(`select p.proname,pg_get_functiondef(p.oid) as definition from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in
  ('sync_member_profile_from_auth','complete_oauth_signup','complete_member_email_verification',
   'assert_member_not_blocked','get_current_auth_account_role','verify_phone_otp','issue_signup_coupons',
   'grant_signup_coupons','get_my_signup_referral','_complete_signup_referral','get_signup_referral_offer')`);
const profile = await query(`select column_name,data_type,is_nullable,column_default from information_schema.columns where table_schema='public' and table_name='member_profiles' order by ordinal_position`);
const access = await query(`select tablename,policyname,roles,cmd,qual,with_check from pg_policies where schemaname='public' and tablename in ('member_profiles','member_coupons','member_point_accounts','member_point_ledger')`);
const indexes = await query(`select tablename,indexname,indexdef from pg_indexes where schemaname='public' and indexdef ilike '%unique%' and tablename in ('cart_items','wishlist_items','member_shipping_addresses','member_settlement_accounts','member_coupons','point_lots','point_transactions','event_subscriptions','restock_notifications','restock_keyword_subscriptions','retention_experiment_members','reviews','member_profiles')`);
const issuance = await query(`select pg_get_functiondef('public.issue_signup_coupons_for_new_member()'::regprocedure) as definition`);
const guards = await query(`select table_name,column_name,privilege_type from information_schema.column_privileges where table_schema='public' and table_name='member_profiles' and grantee='authenticated' and privilege_type='UPDATE'`);
const uuidColumns = await query(`select table_name,column_name from information_schema.columns where table_schema='public' and data_type='uuid' order by table_name,column_name`);
const hooks = await query(`select rolname, unnest(rolconfig) as setting from pg_roles where rolname='authenticator'`);
const businessColumns = await query(`select table_name,column_name,data_type from information_schema.columns where table_schema='public' and table_name in ('member_coupons','cart_items','pg_checkout_sessions','settlements','point_lots','point_transactions','retention_experiment_members') order by table_name,ordinal_position`);
const triggers = await query(`select n.nspname as schema,t.relname as table_name,g.tgname as trigger_name,p.proname as function_name,pg_get_triggerdef(g.oid) as definition from pg_trigger g join pg_class t on t.oid=g.tgrelid join pg_namespace n on n.oid=t.relnamespace join pg_proc p on p.oid=g.tgfoid where not g.tgisinternal and (n.nspname='auth' or t.relname in ('orders','member_coupons','member_profiles','settlements','shipments','point_lots'))`);
const configResponse = await fetch(`https://api.supabase.com/v1/projects/${ref}/config/auth`,{headers:{Authorization:`Bearer ${env.SUPABASE_ACCESS_TOKEN}`},signal:AbortSignal.timeout(30000)});
if (!configResponse.ok) throw Error(`Auth config audit failed: ${configResponse.status}`);
const config = await configResponse.json();
const authConfig = Object.fromEntries(['external_phone_enabled','sms_autoconfirm','mailer_autoconfirm','hook_send_sms_enabled','hook_send_sms_uri','security_manual_linking_enabled'].map(key=>[key,config[key]]));
mkdirSync('.codex/phone-account-audit',{recursive:true});
writeFileSync('.codex/phone-account-audit/schema.json',JSON.stringify({counts,relations,functions,profile,access,indexes,issuance,guards,uuidColumns,hooks,businessColumns,triggers,authConfig},null,2));
console.log(JSON.stringify({counts,authConfig,relations:relations.map(r=>`${r.table_name}.${r.column_name}`),functions:functions.map(r=>r.proname)},null,2));
