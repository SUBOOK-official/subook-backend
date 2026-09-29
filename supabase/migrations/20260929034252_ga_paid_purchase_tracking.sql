-- GA4 실결제 계측. 결제 트랜잭션에는 큐 적재만 수행하며 오류를 전파하지 않는다.
-- 기본 비활성: Vault ga4_measurement_api_secret 검증 후 enabled=true로 활성화.
-- 과거 주문 소급 전송 없음. HTTP 2xx는 수신 확인이며 GA 보고서 처리 보장은 아님.
-- https://developers.google.com/analytics/devguides/collection/protocol/ga4/sending-events
-- 롤백: ga_tracking_config.enabled=false. 큐와 주문 데이터는 보존.
begin;
create table public.ga_tracking_config (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  installed_at timestamptz not null default clock_timestamp()
);
insert into public.ga_tracking_config(singleton) values(true);
create table public.ga_checkout_contexts (
  order_number text primary key,
  client_id text not null check(client_id ~ '^[0-9]{1,20}\.[0-9]{1,20}$'),
  session_id text check(session_id ~ '^[0-9]{1,20}$'),
  experiment_variant text check(experiment_variant in ('control','guide')),
  created_at timestamptz not null default clock_timestamp()
);
create table public.ga_checkout_attempts (
  bucket text primary key, attempts integer not null default 1,
  started_at timestamptz not null default clock_timestamp()
);
create table public.ga_purchase_outbox (
  order_id bigint primary key references public.orders(id) on delete cascade,
  event_time timestamptz not null, payload jsonb,
  status text not null default 'pending' check(status in ('pending','accepted','failed')),
  attempts integer not null default 0, last_http_status integer, last_error text,
  next_attempt_at timestamptz not null default clock_timestamp(), accepted_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);
create index ga_purchase_outbox_due on public.ga_purchase_outbox(next_attempt_at) where status='pending';
alter table public.ga_tracking_config enable row level security;
alter table public.ga_checkout_contexts enable row level security;
alter table public.ga_checkout_attempts enable row level security;
alter table public.ga_purchase_outbox enable row level security;
revoke all on public.ga_tracking_config,public.ga_checkout_contexts,public.ga_checkout_attempts,public.ga_purchase_outbox from public,anon,authenticated;
grant all on public.ga_tracking_config,public.ga_checkout_contexts,public.ga_checkout_attempts,public.ga_purchase_outbox to service_role;

-- 회원/게스트 본인 확인과 시도 제한. IP·전화는 응답이나 저장 데이터에 포함하지 않는다.
create function public.ga_verify_checkout(p_order_number text,p_guest_phone text,p_recent boolean)
returns boolean language plpgsql security definer set search_path='' as $function$
declare h jsonb; owner_id uuid; phone text; created timestamptz; bucket_key text; n integer;
begin
  h:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  if h->>'origin' is distinct from 'https://subook.kr' or length(coalesce(p_order_number,'')) not between 5 and 80 then return false; end if;
  bucket_key:=md5(left(coalesce(h->>'x-forwarded-for','unknown'),100)||':'||coalesce(auth.uid()::text,'guest'));
  insert into public.ga_checkout_attempts(bucket) values(bucket_key)
    on conflict(bucket) do update set
      attempts=case when ga_checkout_attempts.started_at<clock_timestamp()-interval '15 minutes' then 1 else ga_checkout_attempts.attempts+1 end,
      started_at=case when ga_checkout_attempts.started_at<clock_timestamp()-interval '15 minutes' then clock_timestamp() else ga_checkout_attempts.started_at end
    returning attempts into n;
  if n>30 then return false; end if;
  select user_id,shipping_recipient_phone,created_at into owner_id,phone,created from public.orders where order_number=p_order_number;
  if not found then
    select user_id,payload->>'shipping_recipient_phone',created_at into owner_id,phone,created
      from public.pg_checkout_sessions where order_number=p_order_number and status in ('created','completed');
    if not found then return false; end if;
  end if;
  if created<(select installed_at from public.ga_tracking_config where singleton)
    or (p_recent and created<clock_timestamp()-interval '30 minutes') then return false; end if;
  if owner_id is not null then return auth.uid() is not null and auth.uid()=owner_id; end if;
  return auth.uid() is null and length(coalesce(p_guest_phone,'')) between 10 and 30
    and length(regexp_replace(p_guest_phone,'[^0-9]','','g')) between 10 and 11
    and regexp_replace(p_guest_phone,'[^0-9]','','g')=regexp_replace(coalesce(phone,''),'[^0-9]','','g');
end;
$function$;
revoke all on function public.ga_verify_checkout(text,text,boolean) from public,anon,authenticated,service_role;

create function public.ga_enqueue_purchase(p_order_id bigint)
returns boolean language plpgsql security definer set search_path='' as $function$
declare o public.orders%rowtype; c public.ga_checkout_contexts%rowtype; items jsonb; net_value numeric; params jsonb;
begin
  if exists(select 1 from public.ga_purchase_outbox where order_id=p_order_id) then return true; end if;
  select * into o from public.orders where id=p_order_id;
  if not found or o.payment_status not in ('paid','refunded') or o.paid_at is null
    or o.paid_at<clock_timestamp()-interval '48 hours' then return false; end if;
  select * into c from public.ga_checkout_contexts where order_number=o.order_number;
  if not found or o.created_at<(select installed_at from public.ga_tracking_config where singleton) then return false; end if;
  net_value:=greatest(0,o.total_amount-coalesce(o.shipping_fee,0));
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'item_id',oi.product_id::text,'item_name',left(oi.title,100),
    'item_brand',nullif(left(coalesce(p.brand,b.brand),100),''),
    'item_category',nullif(left(coalesce(p.subject,b.subject),100),''),
    'item_variant',left(concat_ws(' · ',oi.option_label,oi.condition_grade),100),
    'price',case when o.subtotal>0 then round(oi.unit_price::numeric*net_value/o.subtotal,6) else 0 end,
    'quantity',oi.quantity)) order by oi.id) into items
  from public.order_items oi left join public.products p on p.id=oi.product_id left join public.books b on b.id=oi.book_id
  where oi.order_id=o.id;
  if items is null or jsonb_array_length(items)>200 or exists(select 1 from public.order_items where order_id=o.id and (product_id is null or quantity<=0)) then return false; end if;
  params:=jsonb_strip_nulls(jsonb_build_object(
    'transaction_id',o.order_number,'currency','KRW','value',net_value,'shipping',coalesce(o.shipping_fee,0),
    'items',items,'payment_type',o.payment_method,'checkout_type',case when o.user_id is null then 'guest' else 'member' end,
    'collection_source','server_paid','guest_checkout_guide_v1',c.experiment_variant,
    'session_id',case when o.paid_at<c.created_at+interval '24 hours' then c.session_id end));
  insert into public.ga_purchase_outbox(order_id,event_time,payload) values(o.id,o.paid_at,
    jsonb_build_object('client_id',c.client_id,'timestamp_micros',floor(extract(epoch from o.paid_at)*1000000)::bigint,
      'consent',jsonb_build_object('ad_user_data','DENIED','ad_personalization','DENIED'),
      'events',jsonb_build_array(jsonb_build_object('name','purchase','params',params)))) on conflict(order_id) do nothing;
  return true;
end;
$function$;
revoke all on function public.ga_enqueue_purchase(bigint) from public,anon,authenticated;
grant execute on function public.ga_enqueue_purchase(bigint) to service_role;

create function public.attach_ga_checkout_context(p_order_number text,p_guest_phone text default null,
  p_client_id text default null,p_session_id text default null,p_experiment_variant text default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare order_id bigint;
begin
  if not coalesce((select enabled from public.ga_tracking_config where singleton),false)
    or p_client_id is null or p_client_id !~ '^[0-9]{1,20}\.[0-9]{1,20}$'
    or not public.ga_verify_checkout(p_order_number,p_guest_phone,true) then return '{"recorded":false}'::jsonb; end if;
  insert into public.ga_checkout_contexts(order_number,client_id,session_id,experiment_variant)
    values(p_order_number,p_client_id,case when p_session_id ~ '^[0-9]{1,20}$' then p_session_id end,
      case when p_experiment_variant in ('control','guide') then p_experiment_variant end) on conflict(order_number) do nothing;
  select id into order_id from public.orders where order_number=p_order_number;
  if order_id is not null then perform public.ga_enqueue_purchase(order_id); end if;
  return '{"recorded":true}'::jsonb;
exception when others then return '{"recorded":false}'::jsonb;
end;
$function$;
revoke all on function public.attach_ga_checkout_context(text,text,text,text,text) from public;
grant execute on function public.attach_ga_checkout_context(text,text,text,text,text) to anon,authenticated,service_role;

-- 완료 화면은 새 체크아웃의 서버 소유 여부를 확인한다. 브라우저 fallback과 동시 전송을 줄인다.
create function public.ga_purchase_delivery_status(p_order_number text,p_guest_phone text default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
begin
  if not public.ga_verify_checkout(p_order_number,p_guest_phone,false) then return '{"server_owned":false}'::jsonb; end if;
  return jsonb_build_object('server_owned',
    exists(select 1 from public.ga_checkout_contexts where order_number=p_order_number)
    or exists(select 1 from public.ga_purchase_outbox q join public.orders o on o.id=q.order_id where o.order_number=p_order_number));
exception when others then return '{"server_owned":false}'::jsonb;
end;
$function$;
revoke all on function public.ga_purchase_delivery_status(text,text) from public;
grant execute on function public.ga_purchase_delivery_status(text,text) to anon,authenticated,service_role;

create function public.ga_on_order_paid() returns trigger language plpgsql security definer set search_path='' as $function$
begin perform public.ga_enqueue_purchase(new.id); return new;
exception when others then return new; end;
$function$;
revoke all on function public.ga_on_order_paid() from public,anon,authenticated,service_role;
create trigger trg_orders_ga_purchase_paid after update of payment_status on public.orders for each row
  when(old.payment_status is distinct from new.payment_status and new.payment_status='paid') execute function public.ga_on_order_paid();

create function public.ga_purchase_http(p_payload jsonb,p_secret text)
returns integer language plpgsql security definer set search_path='' as $function$
declare r record;
begin
  perform set_config('http.curlopt_connecttimeout_ms','2000',true);
  perform set_config('http.curlopt_timeout_ms','8000',true);
  if p_secret !~ '^[A-Za-z0-9_-]+$' then return 0; end if;
  select * into r from extensions.http(row('POST',
    'https://www.google-analytics.com/mp/collect?measurement_id=G-EMNCLZKPMS&api_secret='||p_secret,
    array[]::extensions.http_header[],'application/json',p_payload::text)::extensions.http_request);
  return r.status;
exception when others then return 0; end;
$function$;
revoke all on function public.ga_purchase_http(jsonb,text) from public,anon,authenticated,service_role;

create function public.ga_purchase_sweep() returns void language plpgsql security definer set search_path='' as $function$
declare secret text; r record; http_status integer;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('subook-ga-purchase-sweep',0)) then return; end if;
  for r in select o.id from public.orders o join public.ga_checkout_contexts c using(order_number)
    left join public.ga_purchase_outbox q on q.order_id=o.id
    where q.order_id is null and o.paid_at>=clock_timestamp()-interval '48 hours' and o.payment_status in ('paid','refunded') limit 25
  loop begin perform public.ga_enqueue_purchase(r.id); exception when others then null; end; end loop;
  update public.ga_purchase_outbox set status='failed',last_error='retry_window_exhausted',payload=null
    where status='pending' and (attempts>=8 or event_time<clock_timestamp()-interval '48 hours');
  delete from public.ga_checkout_attempts where started_at<clock_timestamp()-interval '1 day';
  delete from public.ga_checkout_contexts where created_at<clock_timestamp()-interval '7 days';
  delete from public.ga_purchase_outbox where created_at<clock_timestamp()-interval '90 days';
  if not coalesce((select enabled from public.ga_tracking_config where singleton),false) then return; end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name='ga4_measurement_api_secret' limit 1;
  if nullif(secret,'') is null then return; end if;
  for r in select * from public.ga_purchase_outbox where status='pending' and next_attempt_at<=clock_timestamp()
    and payload is not null order by next_attempt_at limit 5 for update skip locked
  loop
    http_status:=public.ga_purchase_http(r.payload,secret);
    update public.ga_purchase_outbox set attempts=attempts+1,last_http_status=http_status,
      status=case when http_status between 200 and 299 then 'accepted' when http_status=0 or http_status=429 or http_status>=500 then 'pending' else 'failed' end,
      accepted_at=case when http_status between 200 and 299 then clock_timestamp() end,
      last_error=case when http_status between 200 and 299 then null else 'http_'||http_status end,
      payload=case when http_status between 200 and 299 or (http_status between 400 and 499 and http_status<>429) then null else payload end,
      next_attempt_at=clock_timestamp()+make_interval(mins=>least(60,power(2,least(r.attempts+1,6))::integer))
      where order_id=r.order_id;
  end loop;
end;
$function$;
revoke all on function public.ga_purchase_sweep() from public,anon,authenticated;
grant execute on function public.ga_purchase_sweep() to service_role;
select cron.schedule('subook-ga-purchase-sweep','* * * * *','select public.ga_purchase_sweep();');
-- 기존 운영 경보의 나머지 점검과 발송 정책을 유지하며 새 크론 감시만 추가한다.
do $guard$
declare definition text; marker text := 'v_expected constant jsonb := jsonb_build_object(';
begin
  if to_regprocedure('public.ops_cron_health_report()') is not null then
    definition:=pg_get_functiondef('public.ops_cron_health_report()'::regprocedure);
    if position(marker in definition)=0 then raise exception '운영 경보 함수 구조를 다시 확인하세요.'; end if;
    definition:=replace(definition,marker,marker||E'\n    ''subook-ga-purchase-sweep'', 15,');
    definition:=replace(definition,'크론 5종','크론 6종');
    execute definition;
  end if;
end;
$guard$;
commit;
