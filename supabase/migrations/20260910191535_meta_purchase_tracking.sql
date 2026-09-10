-- Meta Purchase: 새 운영 체크아웃에 한해 실제 결제 완료 후 서버 전송.
-- 기존 결제/정산 RPC와 상태 전이는 변경하지 않는다. 계측 오류는 결제를 막지 않는다.
-- 토큰은 Vault(meta_capi_access_token), 전송은 별도 pg_cron 작업의 http 확장.
-- https://developers.facebook.com/documentation/ads-commerce/conversions-api/using-the-api
-- https://supabase.com/docs/guides/database/extensions/http
-- Rollback: meta_tracking_config.enabled=false로 전송 중단 후 필요 시 이전 frontend 배포.
-- 테이블/주문 삭제, 기존 주문 소급 전송 없음. API 토큰은 SQL 소스에 넣지 않는다.
begin;
create extension if not exists http with schema extensions;

create table public.meta_tracking_config (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  installed_at timestamptz not null default clock_timestamp()
);
insert into public.meta_tracking_config(singleton) values (true);

create table public.meta_checkout_contexts (
  order_number text primary key,
  fbp text,
  fbc text,
  client_ip_address inet,
  client_user_agent text not null,
  created_at timestamptz not null default clock_timestamp()
);

create table public.meta_checkout_attempts (
  bucket_key text primary key,
  attempts integer not null default 1,
  window_started_at timestamptz not null default clock_timestamp()
);

create table public.meta_purchase_outbox (
  order_id bigint primary key references public.orders(id) on delete cascade,
  event_id text not null unique,
  event_time timestamptz not null,
  payload jsonb,
  status text not null default 'pending' check (status in ('pending','confirmed','failed')),
  attempts integer not null default 0,
  last_http_status integer,
  last_error text,
  next_attempt_at timestamptz not null default clock_timestamp(),
  sent_at timestamptz,
  confirmed_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);
create index meta_purchase_outbox_due on public.meta_purchase_outbox(next_attempt_at)
  where status='pending';

alter table public.meta_tracking_config enable row level security;
alter table public.meta_checkout_contexts enable row level security;
alter table public.meta_checkout_attempts enable row level security;
alter table public.meta_purchase_outbox enable row level security;
revoke all on public.meta_tracking_config, public.meta_checkout_contexts,
  public.meta_checkout_attempts, public.meta_purchase_outbox from public, anon, authenticated;
grant all on public.meta_tracking_config, public.meta_checkout_contexts,
  public.meta_checkout_attempts, public.meta_purchase_outbox to service_role;

-- 기존 pg_net 시스템 테이블은 확장 소유자 권한으로 PUBLIC에 열려 있어,
-- 이 연동의 인증키를 해당 큐에 남기지 않는다. 결제 트리거는 자체 큐 적재만 수행한다.

create function public.meta_enqueue_purchase(p_order_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $function$
declare
  o public.orders%rowtype;
  c public.meta_checkout_contexts%rowtype;
  m public.member_profiles%rowtype;
  v_user_data jsonb;
  v_contents jsonb;
  v_ids jsonb;
  v_count integer;
  v_email text;
  v_phone text;
  v_event_id text;
begin
  if exists(select 1 from public.meta_purchase_outbox where order_id=p_order_id) then return true; end if;
  select * into o from public.orders where id=p_order_id;
  if not found or o.paid_at is null or o.payment_status not in ('paid','refunded') then return false; end if;
  select * into c from public.meta_checkout_contexts where order_number=o.order_number;
  if not found then return false; end if;
  -- 신버전 체크아웃에서 등록된 문맥만 사용. 과거 주문/개발 환경은 자동 편입하지 않는다.
  if o.created_at < (select installed_at from public.meta_tracking_config where singleton) then return false; end if;
  if o.paid_at < clock_timestamp()-interval '7 days' then return false; end if;

  select jsonb_agg(jsonb_build_object(
      'id', case oi.product_id when 2370 then 'gxav9zwrza' when 2371 then '417vdy5t1z'
              when 2437 then 'n7llsz4qrh' else oi.product_id::text end,
      'quantity',oi.quantity,'item_price',oi.unit_price) order by oi.id),
    jsonb_agg(distinct case oi.product_id when 2370 then 'gxav9zwrza' when 2371 then '417vdy5t1z'
              when 2437 then 'n7llsz4qrh' else oi.product_id::text end),
    sum(oi.quantity)::integer
  into v_contents,v_ids,v_count from public.order_items oi where oi.order_id=o.id;
  if v_contents is null or v_count<=0 or exists(
    select 1 from public.order_items where order_id=o.id and (product_id is null or quantity<=0)
  ) then return false; end if;

  v_user_data := jsonb_strip_nulls(jsonb_build_object('fbp',c.fbp,'fbc',c.fbc,
    'client_ip_address',host(c.client_ip_address),'client_user_agent',c.client_user_agent));
  -- 연락처 해시는 마케팅 동의가 있고 탈퇴/차단되지 않은 회원만 추가한다.
  -- 수령인은 주문자와 다를 수 있으므로 배송지 연락처를 고객 식별자로 대체하지 않는다.
  select * into m from public.member_profiles where user_id=o.user_id;
  if found and m.marketing_opt_in and not coalesce(m.is_blocked,false)
     and m.personal_data_erased_at is null and m.withdrawal_requested_at is null then
    v_email := lower(btrim(coalesce(m.email,'')));
    if v_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
      v_user_data := v_user_data || jsonb_build_object('em',jsonb_build_array(encode(extensions.digest(v_email,'sha256'),'hex')));
    end if;
    v_phone := regexp_replace(coalesce(nullif(m.verified_phone,''),m.phone,''),'[^0-9]','','g');
    if v_phone ~ '^01[016789][0-9]{7,8}$' then v_phone := '82'||substr(v_phone,2); end if;
    if v_phone ~ '^821[016789][0-9]{7,8}$' then
      v_user_data := v_user_data || jsonb_build_object('ph',jsonb_build_array(encode(extensions.digest(v_phone,'sha256'),'hex')));
    end if;
  end if;
  v_event_id := 'subook_purchase_' || encode(extensions.digest(o.order_number,'sha256'),'hex');
  insert into public.meta_purchase_outbox(order_id,event_id,event_time,payload)
  values(o.id,v_event_id,o.paid_at,jsonb_build_object(
    'event_name','Purchase','event_id',v_event_id,'event_time',floor(extract(epoch from o.paid_at))::bigint,
    'action_source','website','event_source_url','https://subook.kr/order',
    'user_data',v_user_data,'custom_data',jsonb_build_object(
      'currency','KRW','value',o.total_amount,'order_id',o.order_number,
      'content_type','product','content_ids',v_ids,'contents',v_contents,'num_items',v_count)
  )) on conflict(order_id) do nothing;
  return true;
end;
$function$;
revoke all on function public.meta_enqueue_purchase(bigint) from public,anon,authenticated;
grant execute on function public.meta_enqueue_purchase(bigint) to service_role;

create function public.attach_meta_checkout_context(
  p_order_number text, p_guest_phone text default null, p_fbp text default null, p_fbc text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_headers jsonb;
  v_ip inet;
  v_ip_text text;
  v_ua text;
  v_bucket text;
  v_attempts integer;
  v_number text;
  v_owner uuid;
  v_phone text;
  v_created timestamptz;
  v_order_id bigint;
  v_fbp text;
  v_fbc text;
begin
  v_headers := coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  if coalesce(v_headers->>'origin','') <> 'https://subook.kr' then
    return jsonb_build_object('recorded',false);
  end if;
  v_ua := left(nullif(btrim(v_headers->>'user-agent'),''),1000);
  if v_ua is null then return jsonb_build_object('recorded',false); end if;
  v_ip_text := btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''),',',1));
  begin v_ip := nullif(v_ip_text,'')::inet; exception when others then v_ip := null; end;
  v_bucket := encode(extensions.digest(coalesce(host(v_ip),'unknown')||':'||coalesce(auth.uid()::text,'guest'),'sha256'),'hex');
  insert into public.meta_checkout_attempts(bucket_key) values(v_bucket)
  on conflict(bucket_key) do update set
    attempts=case when meta_checkout_attempts.window_started_at<clock_timestamp()-interval '15 minutes'
      then 1 else meta_checkout_attempts.attempts+1 end,
    window_started_at=case when meta_checkout_attempts.window_started_at<clock_timestamp()-interval '15 minutes'
      then clock_timestamp() else meta_checkout_attempts.window_started_at end
  returning attempts into v_attempts;
  if v_attempts>30 then return jsonb_build_object('recorded',false); end if;

  v_number := upper(btrim(coalesce(p_order_number,'')));
  if length(v_number)<5 or length(v_number)>80 then return jsonb_build_object('recorded',false); end if;
  select id,user_id,shipping_recipient_phone,created_at into v_order_id,v_owner,v_phone,v_created
    from public.orders where order_number=v_number;
  if not found then
    select user_id,payload->>'shipping_recipient_phone',created_at into v_owner,v_phone,v_created
      from public.pg_checkout_sessions where order_number=v_number and status in ('created','completed');
    if not found then return jsonb_build_object('recorded',false); end if;
  end if;
  if v_created<(select installed_at from public.meta_tracking_config where singleton)
     or v_created<clock_timestamp()-interval '30 minutes' then return jsonb_build_object('recorded',false); end if;
  if v_owner is not null then
    if auth.uid() is null or auth.uid()<>v_owner then return jsonb_build_object('recorded',false); end if;
  else
    if auth.uid() is not null or length(coalesce(p_guest_phone,''))>30
       or length(regexp_replace(coalesce(p_guest_phone,''),'[^0-9]','','g'))<10
       or regexp_replace(coalesce(p_guest_phone,''),'[^0-9]','','g')<>
          regexp_replace(coalesce(v_phone,''),'[^0-9]','','g') then
      return jsonb_build_object('recorded',false);
    end if;
  end if;
  -- PostgreSQL 정규식의 반복 상한(255)을 넘기지 않도록 길이는 별도 검사한다.
  if length(p_fbp)<=500 and length(split_part(p_fbp,'.',4))<=450
     and p_fbp ~ '^fb\.[0-9]+\.[0-9]{13}\.[A-Za-z0-9_-]+$' then v_fbp:=p_fbp; end if;
  if length(p_fbc)<=500 and length(split_part(p_fbc,'.',4))<=450
     and p_fbc ~ '^fb\.[0-9]+\.[0-9]{13}\.[A-Za-z0-9_-]+$' then v_fbc:=p_fbc; end if;
  insert into public.meta_checkout_contexts(order_number,fbp,fbc,client_ip_address,client_user_agent)
  values(v_number,v_fbp,v_fbc,v_ip,v_ua) on conflict(order_number) do nothing;
  -- 빠른 결제와 문맥 저장이 경합해도 이미 paid인 주문을 복구한다.
  if v_order_id is not null then perform public.meta_enqueue_purchase(v_order_id); end if;
  return jsonb_build_object('recorded',true);
exception when others then
  -- 연락처/헤더/SQL 오류 원문을 응답이나 로그로 내보내지 않는다.
  return jsonb_build_object('recorded',false);
end;
$function$;
revoke all on function public.attach_meta_checkout_context(text,text,text,text) from public;
grant execute on function public.attach_meta_checkout_context(text,text,text,text) to anon,authenticated,service_role;

create function public.meta_on_order_paid()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  perform public.meta_enqueue_purchase(new.id);
  return new;
exception when others then
  -- 실패 시 매분 스윕이 복구한다. 결제 트랜잭션에는 예외를 전파하지 않는다.
  return new;
end;
$function$;
revoke all on function public.meta_on_order_paid() from public,anon,authenticated;
create trigger trg_orders_meta_purchase_paid
  after update of payment_status on public.orders for each row
  when (old.payment_status is distinct from new.payment_status and new.payment_status='paid')
  execute function public.meta_on_order_paid();

create function public.meta_purchase_http(p_payload jsonb, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  r record;
  v_body jsonb;
begin
  -- 동기 HTTP는 결제 트랜잭션에서 호출하지 않고, 별도 크론에서만 실행한다.
  perform set_config('http.curlopt_connecttimeout_ms','2000',true);
  perform set_config('http.curlopt_timeout_ms','10000',true);
  select * into r from extensions.http(row(
    'POST','https://graph.facebook.com/v26.0/27962792746720705/events',
    array[row('Authorization','Bearer '||p_token)::extensions.http_header],
    'application/json',jsonb_build_object('data',jsonb_build_array(p_payload))::text
  )::extensions.http_request);
  begin v_body:=r.content::jsonb; exception when others then v_body:='{}'::jsonb; end;
  return jsonb_build_object('http_status',r.status,'events_received',v_body->'events_received',
    'error_code',v_body#>'{error,code}','transient',
    r.status=429 or r.status>=500 or coalesce(v_body#>>'{error,is_transient}','false')='true');
exception when others then
  -- 원문 오류/응답/Authorization은 기록하거나 반환하지 않는다.
  return '{"http_status":null,"transient":true}'::jsonb;
end;
$function$;
revoke all on function public.meta_purchase_http(jsonb,text) from public,anon,authenticated,service_role;

create function public.meta_purchase_sweep()
returns void language plpgsql security definer set search_path = '' as $function$
declare
  v_token text;
  r record;
  v_result jsonb;
  v_retry boolean;
  v_error text;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('subook-meta-purchase-sweep',0)) then return; end if;

  -- 트리거 예외/등록 경합 복구. 신규 문맥이 있는 실제 결제만, 과거 주문 소급 없음.
  for r in select o.id from public.orders o
    join public.meta_checkout_contexts c on c.order_number=o.order_number
    left join public.meta_purchase_outbox q on q.order_id=o.id
    where q.order_id is null and o.paid_at>=clock_timestamp()-interval '7 days'
      and o.payment_status in ('paid','refunded') order by o.paid_at limit 25
  loop
    begin perform public.meta_enqueue_purchase(r.id); exception when others then null; end;
  end loop;

  update public.meta_purchase_outbox set status='failed',last_error='retry_window_exhausted'
    where status='pending' and (attempts>=12 or event_time<clock_timestamp()-interval '36 hours');
  -- 개인정보와 해시도 무기한 보관하지 않는다. 성공 payload는 위에서 즉시 제거한다.
  update public.meta_purchase_outbox set payload=null where payload is not null and created_at<clock_timestamp()-interval '7 days';
  delete from public.meta_checkout_contexts where created_at<clock_timestamp()-interval '7 days';
  delete from public.meta_checkout_attempts where window_started_at<clock_timestamp()-interval '1 day';
  delete from public.meta_purchase_outbox where created_at<clock_timestamp()-interval '90 days';

  if not coalesce((select enabled from public.meta_tracking_config where singleton),false) then return; end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name='meta_capi_access_token' limit 1;
  if nullif(btrim(v_token),'') is null then return; end if;
  for r in select * from public.meta_purchase_outbox
    where status='pending' and next_attempt_at<=clock_timestamp() and payload is not null
    order by next_attempt_at limit 5 for update skip locked
  loop
    begin
      v_result:=public.meta_purchase_http(r.payload,v_token);
      if v_result->>'http_status'='200' and v_result->>'events_received'='1' then
        update public.meta_purchase_outbox set status='confirmed',attempts=attempts+1,
          sent_at=clock_timestamp(),confirmed_at=clock_timestamp(),last_http_status=200,
          last_error=null,payload=null where order_id=r.order_id;
      else
        v_retry:=coalesce(v_result->>'transient','false')='true';
        v_error:='http_'||coalesce(v_result->>'http_status','timeout')||'_graph_'||coalesce(v_result->>'error_code','unknown');
        update public.meta_purchase_outbox set status=case when v_retry then 'pending' else 'failed' end,
          attempts=attempts+1,sent_at=clock_timestamp(),last_http_status=(v_result->>'http_status')::integer,
          last_error=v_error,next_attempt_at=clock_timestamp()+make_interval(mins=>least(60,power(2,least(r.attempts+1,6))::integer))
          where order_id=r.order_id;
      end if;
    exception when others then
      update public.meta_purchase_outbox set attempts=attempts+1,last_error='transport_failed',
        next_attempt_at=clock_timestamp()+interval '5 minutes' where order_id=r.order_id;
    end;
  end loop;
end;
$function$;
revoke all on function public.meta_purchase_sweep() from public,anon,authenticated;
grant execute on function public.meta_purchase_sweep() to service_role;
select cron.schedule('subook-meta-purchase-sweep','* * * * *','select public.meta_purchase_sweep();');

comment on table public.meta_checkout_contexts is '새 운영 체크아웃의 Meta 쿠키/접속 문맥. 본인 확인 RPC 전용, 7일 정리.';
comment on table public.meta_purchase_outbox is '결제 완료 Meta Purchase 전송 큐. 원문 연락처 없음, 성공 payload 즉시 제거, 재시도 동일 event_id.';
comment on table public.meta_tracking_config is 'Meta 서버 Purchase 전송 스위치. 기본 false, 토큰 검증과 frontend 전환 후 활성화.';
commit;
