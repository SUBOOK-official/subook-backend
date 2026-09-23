-- 구글시트 동기화: 즉시 동시 발송 제거, 단일 HTTP 배치, JSON 응답 검증.
-- 기존 실패 기록은 보존한다. 운영 대조/복구는 별도 감사 기록과 함께 수행한다.
-- 롤백: cron을 */5로 복원하고 20260804033000의 함수 정의를 복원.
-- 새 열은 제거하지 않아 복구 이력을 보존한다. Apps Script v3 배포가 선행되어야 함.
begin;

alter table public.gsheet_sync_outbox
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution_note text;

create index if not exists idx_gsheet_sync_outbox_due
  on public.gsheet_sync_outbox(next_attempt_at, id)
  where status = 'pending' and resolved_at is null;

-- serial 없는 자체 판매 교재는 재고 시트의 멱등 키가 없다. 시트 전송 대상에서 제외.
-- null -> serial 할당 시 아래 UPDATE 트리거가 정상 재고를 다시 적재한다.
create or replace function public.gsheet_sync_enqueue(p_kind text, p_dedupe_key text, p_rows jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text; v_token text;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then return; end if;
  if p_kind not in ('sale','inventory') or nullif(btrim(p_dedupe_key),'') is null then return; end if;
  if p_kind = 'inventory' and exists (
    select 1 from jsonb_array_elements(p_rows) r where nullif(btrim(r->>0),'') is null
  ) then return; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token from vault.decrypted_secrets where name='gsheet_sync_token' limit 1;
  if nullif(btrim(v_url),'') is null or nullif(v_token,'') is null then return; end if;
  -- 같은 키로 동시에 들어온 트리거도 한 번만 적재한다.
  perform pg_advisory_xact_lock(hashtextextended('gsheet:' || p_kind || ':' || p_dedupe_key,0));
  if exists(select 1 from public.gsheet_sync_outbox where kind=p_kind and dedupe_key=p_dedupe_key
      and resolved_at is null and status in ('pending','sent','confirmed')) then return; end if;
  insert into public.gsheet_sync_outbox(kind,dedupe_key,rows) values(p_kind,p_dedupe_key,p_rows);
end;
$$;

create trigger trg_books_gsheet_on_serial_assigned
after update of serial_number on public.books for each row
when (old.serial_number is null and new.serial_number is not null and new.status = 'on_sale')
execute function public.notify_gsheet_book_registered();

create or replace function public.gsheet_sync_sweep()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url text; v_token text; r record; v_resp record; v_body jsonb;
  v_error text; v_permanent boolean; v_req bigint; v_ids bigint[]; v_rows jsonb; v_kind text;
begin
  -- cron/수동 실행이 겹쳐도 전송자는 하나. HTTP 완료 전에는 다음 배치도 발송하지 않는다.
  if not pg_try_advisory_xact_lock(hashtextextended('gsheet:dispatcher',0)) then return; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token from vault.decrypted_secrets where name='gsheet_sync_token' limit 1;
  if nullif(btrim(v_url),'') is null or nullif(v_token,'') is null then return; end if;

  for r in select * from public.gsheet_sync_outbox where status='sent' and resolved_at is null for update
  loop
    select * into v_resp from net._http_response where id=r.last_request_id;
    if not found and r.sent_at > now()-interval '10 minutes' then continue; end if;
    v_body := null; v_error := null; v_permanent := false;
    if not found then
      v_error := 'no response row';
    else
      begin v_body := v_resp.content::jsonb; exception when others then v_body := null; end;
      if v_resp.status_code=200 and v_body->'ok'='true'::jsonb
         and (r.kind <> 'ping' or v_body->>'v'='3') then
        update public.gsheet_sync_outbox set status='confirmed',confirmed_at=now(),last_error=null,updated_at=now() where id=r.id;
        continue;
      end if;
      -- HTML 문구에 'not found'가 있다는 이유로 영구 실패 처리하지 않는다.
      v_error := coalesce(v_body->>'error',nullif(v_resp.error_msg,''),
        'http ' || coalesce(v_resp.status_code::text,'null') || ' non-success response');
      v_permanent := coalesce(v_body->>'error','') in (
        'unauthorized','unknown kind','sales sheet not found','inventory sheet not found',
        'missing_order_number','missing_serial_number','missing_order_header','existing_order_conflict');
    end if;
    update public.gsheet_sync_outbox
       set status=case when v_permanent or attempts>=10 then 'failed' else 'pending' end,
           last_error=left(v_error,300),updated_at=now(),
           next_attempt_at=now()+make_interval(mins=>least(60,5*greatest(attempts,1)))
     where id=r.id;
  end loop;
  if exists(select 1 from public.gsheet_sync_outbox where status='sent' and resolved_at is null) then return; end if;

  -- 과거 잘못된 페이로드도 절대 재발송하지 않는다.
  update public.gsheet_sync_outbox set status='failed',last_error='missing_serial_number',updated_at=now()
   where status='pending' and resolved_at is null and kind='inventory'
     and (nullif(btrim(dedupe_key),'') is null or exists(
       select 1 from jsonb_array_elements(rows) x where nullif(btrim(x->>0),'') is null));
  update public.gsheet_sync_outbox set status='failed',updated_at=now()
   where status='pending' and resolved_at is null and attempts>=10;
  if not exists(select 1 from public.gsheet_sync_outbox where status='pending' and kind<>'ping'
     and resolved_at is null and next_attempt_at<=now()) then return; end if;

  -- 새 버전에서만 재시도: 과거 v2 ping은 통과 근거가 아니다. 매일 갱신한다.
  if not exists(select 1 from public.gsheet_sync_outbox where kind='ping' and dedupe_key='protocol-v3'
      and status='confirmed' and confirmed_at>now()-interval '1 day') then
    if exists(select 1 from public.gsheet_sync_outbox where kind='ping' and dedupe_key='protocol-v3'
       and created_at>now()-interval '15 minutes') then return; end if;
    v_req:=net.http_post(url:=v_url,body:=jsonb_build_object('token',v_token,'kind','ping'),timeout_milliseconds:=120000);
    insert into public.gsheet_sync_outbox(kind,dedupe_key,rows,status,attempts,last_request_id,sent_at)
      values('ping','protocol-v3','[]','sent',1,v_req,now());
    return;
  end if;

  -- 오래된 재시도는 next_attempt_at으로 뒤로 밀어 새 요청을 굶기지 않는다.
  select kind into v_kind from public.gsheet_sync_outbox
    where status='pending' and kind<>'ping' and resolved_at is null and next_attempt_at<=now()
    order by next_attempt_at,id limit 1;
  select array_agg(q.id order by q.next_attempt_at,q.id) into v_ids from (
    select id,next_attempt_at from public.gsheet_sync_outbox
     where status='pending' and kind=v_kind and resolved_at is null and next_attempt_at<=now()
     order by next_attempt_at,id limit (case when v_kind='inventory' then 20 else 1 end)
     for update skip locked
  ) q;
  if v_ids is null then return; end if;
  select jsonb_agg(x.value order by array_position(v_ids,o.id),x.ordinality) into v_rows
    from public.gsheet_sync_outbox o cross join lateral jsonb_array_elements(o.rows) with ordinality x
    where o.id=any(v_ids);
  -- pg_net은 비동기이므로 loop 2회는 직렬화가 아니었다. HTTP 요청 자체를 하나로 묶는다.
  v_req:=net.http_post(url:=v_url,
    body:=jsonb_build_object('token',v_token,'kind',v_kind,'rows',v_rows),timeout_milliseconds:=120000);
  update public.gsheet_sync_outbox set status='sent',attempts=attempts+1,last_request_id=v_req,
    sent_at=now(),updated_at=now() where id=any(v_ids);
end;
$$;

-- 기존 아웃박스를 재사용해 성공 후 옛 failed가 경보에 남지 않도록 한다.
create or replace function public.admin_gsheet_resend_order(p_order_number text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_order public.orders%rowtype; v_id bigint; v_rows jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended('gsheet:sale:' || p_order_number,0));
  select * into v_order from public.orders where order_number=p_order_number;
  if not found then return jsonb_build_object('ok',false,'reason','order_not_found'); end if;
  if v_order.payment_status is distinct from 'paid' or v_order.status in ('cancelled','refunded')
     or exists(select 1 from public.order_items where order_id=v_order.id and refunded_at is not null) then
    return jsonb_build_object('ok',false,'reason','payment_or_refund_requires_review');
  end if;
  select id into v_id from public.gsheet_sync_outbox where kind='sale' and dedupe_key=p_order_number
    and resolved_at is null order by (status in ('confirmed','sent','pending')) desc,id desc limit 1 for update;
  if v_id is not null and exists(select 1 from public.gsheet_sync_outbox where id=v_id and status<>'failed') then
    return jsonb_build_object('ok',true,'outbox_id',v_id,'already_queued_or_confirmed',true);
  end if;
  v_rows:=public.build_gsheet_sale_rows(v_order.id);
  if v_rows is null then return jsonb_build_object('ok',false,'reason','no_items'); end if;
  if v_id is null then
    insert into public.gsheet_sync_outbox(kind,dedupe_key,rows) values('sale',p_order_number,v_rows) returning id into v_id;
  else
    update public.gsheet_sync_outbox set rows=v_rows,status='pending',attempts=0,last_error=null,
      last_request_id=null,next_attempt_at=now(),updated_at=now() where id=v_id;
  end if;
  return jsonb_build_object('ok',true,'outbox_id',v_id);
end;
$$;

revoke all on function public.gsheet_sync_enqueue(text,text,jsonb) from public,anon,authenticated;
revoke all on function public.gsheet_sync_sweep() from public,anon,authenticated;
revoke all on function public.admin_gsheet_resend_order(text) from public,anon,authenticated;
grant execute on function public.gsheet_sync_sweep() to service_role;
grant execute on function public.admin_gsheet_resend_order(text) to service_role;
select cron.schedule('subook-gsheet-sync-sweep','* * * * *',$job$ select public.gsheet_sync_sweep(); $job$);

-- 기존 크론 목록/정산 알림/정상 일일 리포트는 그대로 보존한다.
do $$
declare v_old text; v_new text;
begin
  v_old:=pg_get_functiondef('public.ops_cron_health_report()'::regprocedure);
  v_new:=replace(v_old,
    'from gsheet_sync_outbox where status = ''failed'';',
    'from gsheet_sync_outbox where status = ''failed'' and resolved_at is null;');
  v_new:=replace(v_new,
    '· 구글시트 아웃박스 failed %s건 — admin_gsheet_resend_order로 재기록 필요',
    '· 구글시트 미해결 실패 %s건 — kind·last_error 확인 후 시트 대조 필요 (일괄 재전송 금지)');
  v_new:=replace(v_new,
    'where status = ''pending''
    and created_at',
    'where status in (''pending'', ''sent'') and resolved_at is null
    and created_at');
  v_new:=replace(v_new,'· 구글시트 아웃박스 pending 정체 %s건 (1h+)','· 구글시트 전송 미확인 %s건 (1h+)');
  if v_new=v_old or position('and resolved_at is null' in v_new)=0 then
    raise exception 'ops_cron_health_report definition changed; review before migration';
  end if;
  execute v_new;
end;
$$;
commit;
