import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
const db = new PGlite();
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth; create schema extensions; create schema vault; create schema cron;
    create function auth.uid() returns uuid language sql as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
    create function cron.schedule(text,text,text) returns bigint language sql as 'select 1::bigint';
    create function public.ops_cron_health_report() returns jsonb language plpgsql as $$
      declare v_expected constant jsonb := jsonb_build_object('existing-job',60);
      begin return v_expected; end; $$;
    create type extensions.http_header as (field text,value text);
    create type extensions.http_request as (method text,uri text,headers extensions.http_header[],content_type text,content text);
    create function extensions.http(extensions.http_request) returns table(status int,content text) language sql as $$select coalesce(nullif(current_setting('test.http',true),'')::int,204),''::text$$;
    create table vault.decrypted_secrets(name text,decrypted_secret text);
    create table orders(id bigint primary key,order_number text unique,user_id uuid,shipping_recipient_phone text,
      created_at timestamptz default now(),paid_at timestamptz,payment_status text default 'pending',payment_method text default 'card',
      total_amount integer default 14000,subtotal integer default 12000,shipping_fee integer default 3000);
    create table pg_checkout_sessions(order_number text,user_id uuid,payload jsonb,created_at timestamptz,status text);
    create table products(id bigint,brand text,subject text);
    create table books(id bigint,brand text,subject text);
    create table order_items(id bigint,order_id bigint,product_id bigint,book_id bigint,title text,option_label text,condition_grade text,unit_price integer,quantity integer);
    insert into products values(1,'시대인재','수학');
  `);
  await db.exec(readFileSync(new URL('../supabase/migrations/20260929034252_ga_paid_purchase_tracking.sql',import.meta.url),'utf8'));
  assert.deepEqual((await db.query('select ops_cron_health_report() data')).rows[0].data,{'existing-job':60,'subook-ga-purchase-sweep':15});
  await db.exec(`update ga_tracking_config set installed_at=now()-interval '1 minute';
    insert into orders(id,order_number,user_id,shipping_recipient_phone) values(1,'TEST-1',null,'01011112222'),(2,'TEST-2','00000000-0000-4000-8000-000000000001','01011112222');
    insert into order_items values(1,1,1,1,'교재','1회','S',12000,1),(2,2,1,1,'교재','1회','S',12000,1);
    select set_config('request.headers','{"origin":"https://subook.kr","x-forwarded-for":"127.0.0.1"}',false);`);
  const attach = (number='TEST-1', phone='01011112222', cid='123.456') => db.query('select attach_ga_checkout_context($1,$2,$3,$4,$5) as result',[number,phone,cid,'1234567890','guide']);
  assert.equal((await attach()).rows[0].result.recorded,false,'disabled by default');
  await db.exec('update ga_tracking_config set enabled=true');
  assert.equal((await attach('TEST-1','01000000000')).rows[0].result.recorded,false,'wrong phone');
  assert.equal((await attach('TEST-1','01011112222','injected@email.test')).rows[0].result.recorded,false,'invalid client id');
  assert.equal((await attach('TEST-2')).rows[0].result.recorded,false,'guest cannot claim member');
  assert.equal((await attach()).rows[0].result.recorded,true);
  assert.equal((await db.query('select count(*)::int n from ga_purchase_outbox')).rows[0].n,0,'pending order excluded');
  await db.exec("update orders set payment_status='paid',paid_at=now() where id=1");
  const row=(await db.query('select * from ga_purchase_outbox')).rows[0];
  const params=row.payload.events[0].params;
  assert.equal(params.value,11000); assert.equal(params.shipping,3000);
  assert.equal(params.items[0].item_brand,'시대인재'); assert.equal(params.items[0].item_category,'수학');
  assert.equal(params.items[0].price,11000); assert.equal(params.guest_checkout_guide_v1,'guide');
  assert.ok(!JSON.stringify(row.payload).includes('01011112222'));
  await attach(); await db.exec('select ga_enqueue_purchase(1)');
  assert.equal((await db.query('select count(*)::int n from ga_purchase_outbox')).rows[0].n,1,'one row per order');
  await db.exec("insert into vault.decrypted_secrets values('ga4_measurement_api_secret','test_secret'); select set_config('test.http','503',false); select ga_purchase_sweep();");
  assert.equal((await db.query('select status from ga_purchase_outbox')).rows[0].status,'pending','server failure retry');
  await db.exec("update ga_purchase_outbox set next_attempt_at=now(); select set_config('test.http','204',false); select ga_purchase_sweep();");
  const accepted=(await db.query('select * from ga_purchase_outbox')).rows[0];
  assert.equal(accepted.status,'accepted'); assert.equal(accepted.payload,null); assert.equal(accepted.attempts,2);
  await db.exec("select set_config('test.uid','00000000-0000-4000-8000-000000000001',false)");
  assert.equal((await attach('TEST-2')).rows[0].result.recorded,true);
  await db.exec("update orders set payment_status='paid',paid_at=now() where id=2; update ga_purchase_outbox set event_time=now()-interval '49 hours' where order_id=2; select ga_purchase_sweep();");
  assert.equal((await db.query('select status from ga_purchase_outbox where order_id=2')).rows[0].status,'failed','expired event not retimed');
  const permissions=(await db.query("select has_table_privilege('anon','ga_purchase_outbox','select') allowed, has_function_privilege('anon','ga_purchase_sweep()','execute') can_send, relrowsecurity rls from pg_class where oid='ga_purchase_outbox'::regclass")).rows[0];
  assert.deepEqual(permissions,{allowed:false,can_send:false,rls:true});
  console.log('PASS: ownership, default disabled, paid-only, metadata/discount, no PII, dedup, retry/2xx, expiry, RLS');
} catch(error) { console.error(error.message, error.where ?? ''); process.exitCode=1; }
finally { await db.close(); }
