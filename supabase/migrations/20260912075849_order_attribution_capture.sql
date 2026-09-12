-- 주문 출처를 GA4 세션 귀속과 별도로 보존한다.
-- 브라우저는 원시 click id나 임의 query string을 보내지 않고, 정규화한 최초/최종 터치만 전송한다.
-- 카드 결제는 pg_checkout_sessions 단계에서 문맥을 받아 주문 INSERT 시 자동 복사한다.
-- 무통장/토스처럼 주문이 먼저 생긴 경로는 RPC가 생성된 주문에 즉시 기록한다.
-- Rollback: trigger/function/context tables를 제거하고 orders.attribution 컬럼을 제거한다.
begin;

alter table public.orders
  add column if not exists attribution jsonb;

comment on column public.orders.attribution is
  '주문 당시 최초/최종 유입 스냅샷. 원시 광고 클릭 ID와 전체 URL은 저장하지 않는다.';

create table public.order_attribution_contexts (
  order_number text primary key,
  attribution jsonb not null check (jsonb_typeof(attribution) = 'object'),
  created_at timestamptz not null default clock_timestamp()
);

create table public.order_attribution_attempts (
  bucket_key text primary key,
  attempts integer not null default 1,
  window_started_at timestamptz not null default clock_timestamp()
);

alter table public.order_attribution_contexts enable row level security;
alter table public.order_attribution_attempts enable row level security;
revoke all on public.order_attribution_contexts, public.order_attribution_attempts
  from public, anon, authenticated;
grant all on public.order_attribution_contexts, public.order_attribution_attempts to service_role;

create function public.sanitize_order_attribution_touch(p_touch jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $function$
declare
  v_click_types jsonb;
  v_source text;
  v_medium text;
  v_referrer_host text;
  v_landing_path text;
begin
  if p_touch is null or jsonb_typeof(p_touch) <> 'object' then
    return null;
  end if;

  v_source := nullif(left(btrim(regexp_replace(coalesce(p_touch->>'source', ''), '[[:cntrl:]]', '', 'g')), 100), '');
  v_medium := nullif(left(btrim(regexp_replace(coalesce(p_touch->>'medium', ''), '[[:cntrl:]]', '', 'g')), 100), '');
  if v_source is null or v_medium is null then
    return null;
  end if;

  v_referrer_host := lower(nullif(left(btrim(regexp_replace(coalesce(p_touch->>'referrer_host', ''), '[[:cntrl:]]', '', 'g')), 253), ''));
  if v_referrer_host is not null and v_referrer_host !~ '^[a-z0-9.-]+$' then
    v_referrer_host := null;
  end if;

  v_landing_path := nullif(left(btrim(regexp_replace(coalesce(p_touch->>'landing_path', ''), '[[:cntrl:]]', '', 'g')), 500), '');
  if v_landing_path is not null and left(v_landing_path, 1) <> '/' then
    v_landing_path := null;
  end if;

  select coalesce(jsonb_agg(v order by v), '[]'::jsonb)
    into v_click_types
  from (
    select distinct value as v
    from jsonb_array_elements_text(
      case when jsonb_typeof(p_touch->'click_id_types') = 'array'
        then p_touch->'click_id_types' else '[]'::jsonb end
    )
    where value = any(array['gclid', 'gbraid', 'wbraid', 'dclid', 'fbclid'])
  ) allowed;

  return jsonb_strip_nulls(jsonb_build_object(
    'source', v_source,
    'medium', v_medium,
    'campaign', nullif(left(btrim(regexp_replace(coalesce(p_touch->>'campaign', ''), '[[:cntrl:]]', '', 'g')), 200), ''),
    'campaign_id', nullif(left(btrim(regexp_replace(coalesce(p_touch->>'campaign_id', ''), '[[:cntrl:]]', '', 'g')), 200), ''),
    'content', nullif(left(btrim(regexp_replace(coalesce(p_touch->>'content', ''), '[[:cntrl:]]', '', 'g')), 200), ''),
    'term', nullif(left(btrim(regexp_replace(coalesce(p_touch->>'term', ''), '[[:cntrl:]]', '', 'g')), 200), ''),
    'source_platform', nullif(left(btrim(regexp_replace(coalesce(p_touch->>'source_platform', ''), '[[:cntrl:]]', '', 'g')), 100), ''),
    'click_id_types', case when jsonb_array_length(v_click_types) > 0 then v_click_types else null end,
    'referrer_host', v_referrer_host,
    'landing_path', v_landing_path,
    'captured_at', case
      when coalesce(p_touch->>'captured_at', '') ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T'
        then left(p_touch->>'captured_at', 40)
      else null
    end
  ));
end;
$function$;

create function public.sanitize_order_attribution(p_attribution jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $function$
declare
  v_first jsonb;
  v_last jsonb;
begin
  if p_attribution is null
     or jsonb_typeof(p_attribution) <> 'object'
     or octet_length(p_attribution::text) > 8192 then
    return null;
  end if;

  v_first := public.sanitize_order_attribution_touch(p_attribution->'first_touch');
  v_last := public.sanitize_order_attribution_touch(p_attribution->'last_touch');
  if v_first is null then return null; end if;
  if v_last is null then v_last := v_first; end if;

  return jsonb_build_object(
    'version', 1,
    'first_touch', v_first,
    'last_touch', v_last
  );
end;
$function$;

revoke all on function public.sanitize_order_attribution_touch(jsonb) from public, anon, authenticated;
revoke all on function public.sanitize_order_attribution(jsonb) from public, anon, authenticated;

create function public.attach_order_attribution_context(
  p_order_number text,
  p_guest_phone text default null,
  p_attribution jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_headers jsonb;
  v_ip inet;
  v_ip_text text;
  v_bucket text;
  v_attempts integer;
  v_number text;
  v_owner uuid;
  v_phone text;
  v_created timestamptz;
  v_order_id bigint;
  v_attribution jsonb;
begin
  v_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  if coalesce(v_headers->>'origin', '') <> 'https://subook.kr' then
    return jsonb_build_object('recorded', false);
  end if;

  v_ip_text := btrim(split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1));
  begin
    v_ip := nullif(v_ip_text, '')::inet;
  exception when others then
    v_ip := null;
  end;
  v_bucket := encode(extensions.digest(
    coalesce(host(v_ip), 'unknown') || ':' || coalesce(auth.uid()::text, 'guest'),
    'sha256'
  ), 'hex');
  insert into public.order_attribution_attempts(bucket_key) values (v_bucket)
  on conflict (bucket_key) do update set
    attempts = case
      when order_attribution_attempts.window_started_at < clock_timestamp() - interval '15 minutes'
        then 1 else order_attribution_attempts.attempts + 1 end,
    window_started_at = case
      when order_attribution_attempts.window_started_at < clock_timestamp() - interval '15 minutes'
        then clock_timestamp() else order_attribution_attempts.window_started_at end
  returning attempts into v_attempts;
  if v_attempts > 30 then return jsonb_build_object('recorded', false); end if;

  v_number := upper(btrim(coalesce(p_order_number, '')));
  if length(v_number) < 5 or length(v_number) > 80 then
    return jsonb_build_object('recorded', false);
  end if;
  v_attribution := public.sanitize_order_attribution(p_attribution);
  if v_attribution is null then return jsonb_build_object('recorded', false); end if;
  v_attribution := v_attribution || jsonb_build_object('recorded_at', clock_timestamp());

  -- PG finalize의 주문 INSERT와 같은 번호로 직렬화해, 어느 쪽이 먼저 와도
  -- 문맥이 주문 또는 임시 테이블 중 정확히 한 곳에 남게 한다.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('subook-order-attribution:' || v_number, 0)
  );

  select id, user_id, shipping_recipient_phone, created_at
    into v_order_id, v_owner, v_phone, v_created
  from public.orders
  where order_number = v_number;

  if not found then
    select user_id, payload->>'shipping_recipient_phone', created_at
      into v_owner, v_phone, v_created
    from public.pg_checkout_sessions
    where order_number = v_number and status in ('created', 'completed');
    if not found then return jsonb_build_object('recorded', false); end if;
  end if;

  if v_created < clock_timestamp() - interval '30 minutes' then
    return jsonb_build_object('recorded', false);
  end if;
  if v_owner is not null then
    if auth.uid() is null or auth.uid() <> v_owner then
      return jsonb_build_object('recorded', false);
    end if;
  else
    if auth.uid() is not null
       or length(coalesce(p_guest_phone, '')) > 30
       or length(regexp_replace(coalesce(p_guest_phone, ''), '[^0-9]', '', 'g')) < 10
       or regexp_replace(coalesce(p_guest_phone, ''), '[^0-9]', '', 'g') <>
          regexp_replace(coalesce(v_phone, ''), '[^0-9]', '', 'g') then
      return jsonb_build_object('recorded', false);
    end if;
  end if;

  if v_order_id is not null then
    update public.orders
      set attribution = coalesce(attribution, v_attribution)
    where id = v_order_id;
  else
    insert into public.order_attribution_contexts(order_number, attribution)
    values (v_number, v_attribution)
    on conflict (order_number) do nothing;
  end if;

  return jsonb_build_object('recorded', true);
exception when others then
  -- 출처 저장 오류는 주문/결제를 막거나 원문을 외부에 노출하지 않는다.
  return jsonb_build_object('recorded', false);
end;
$function$;

revoke all on function public.attach_order_attribution_context(text, text, jsonb) from public;
grant execute on function public.attach_order_attribution_context(text, text, jsonb)
  to anon, authenticated, service_role;

create function public.apply_order_attribution_context()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_attribution jsonb;
begin
  if new.attribution is not null then return new; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('subook-order-attribution:' || new.order_number, 0)
  );
  delete from public.order_attribution_contexts
  where order_number = new.order_number
  returning attribution into v_attribution;
  if v_attribution is not null then new.attribution := v_attribution; end if;
  return new;
end;
$function$;

revoke all on function public.apply_order_attribution_context() from public, anon, authenticated;
create trigger trg_orders_apply_attribution_context
  before insert on public.orders
  for each row execute function public.apply_order_attribution_context();

create function public.get_admin_order_attributions(p_order_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if coalesce(cardinality(p_order_ids), 0) > 100 then raise exception 'Too many order ids'; end if;
  select coalesce(jsonb_object_agg(o.id::text, o.attribution), '{}'::jsonb)
    into v_result
  from public.orders o
  where o.id = any(coalesce(p_order_ids, '{}'::bigint[]))
    and o.attribution is not null;
  return v_result;
end;
$function$;

revoke all on function public.get_admin_order_attributions(bigint[]) from public, anon;
grant execute on function public.get_admin_order_attributions(bigint[]) to authenticated, service_role;

create function public.cleanup_order_attribution_contexts()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  delete from public.order_attribution_contexts
    where created_at < clock_timestamp() - interval '1 day';
  delete from public.order_attribution_attempts
    where window_started_at < clock_timestamp() - interval '1 day';
end;
$function$;

revoke all on function public.cleanup_order_attribution_contexts()
  from public, anon, authenticated;
grant execute on function public.cleanup_order_attribution_contexts() to service_role;

do $schedule$
declare
  v_job_id bigint;
begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    select jobid into v_job_id from cron.job
      where jobname = 'subook-order-attribution-cleanup' limit 1;
    if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
    perform cron.schedule(
      'subook-order-attribution-cleanup',
      '41 18 * * *',
      'select public.cleanup_order_attribution_contexts();'
    );
  end if;
end;
$schedule$;

comment on table public.order_attribution_contexts is
  '카드 주문 생성 전 출처 임시 문맥. 주문 INSERT 시 소모되고 미완료 문맥은 1일 뒤 삭제.';
comment on function public.attach_order_attribution_context(text, text, jsonb) is
  '새 주문/PG 세션 소유권을 확인한 뒤 정규화된 최초·최종 유입을 주문에 연결.';

notify pgrst, 'reload schema';
commit;
