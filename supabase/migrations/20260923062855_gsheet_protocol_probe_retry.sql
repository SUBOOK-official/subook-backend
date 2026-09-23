-- 승인/배포 대기 중 v2 응답을 받은 probe도 backoff 이후 같은 행으로 재시도한다.
-- 데이터/권한 변경 없음. 롤백은 아래 삽입 블록만 함수에서 제거한다.
begin;
do $$
declare v_old text; v_marker text; v_retry text;
begin
  v_old:=pg_get_functiondef('public.gsheet_sync_sweep()'::regprocedure);
  v_marker:=$marker$    if exists(select 1 from public.gsheet_sync_outbox where kind='ping' and dedupe_key='protocol-v3'
       and created_at>now()-interval '15 minutes') then return; end if;$marker$;
  v_retry:=$retry$    select * into r from public.gsheet_sync_outbox
      where kind='ping' and dedupe_key='protocol-v3' and status='pending'
        and resolved_at is null and attempts<10 and next_attempt_at<=now()
      order by id desc limit 1 for update;
    if found then
      v_req:=net.http_post(url:=v_url,body:=jsonb_build_object('token',v_token,'kind','ping'),timeout_milliseconds:=120000);
      update public.gsheet_sync_outbox set status='sent',attempts=attempts+1,
        last_request_id=v_req,sent_at=now(),updated_at=now() where id=r.id;
      return;
    end if;
$retry$;
  if position(v_marker in v_old)=0 then raise exception 'gsheet probe gate changed; review before migration'; end if;
  execute replace(v_old,v_marker,v_retry || v_marker);
end;
$$;
commit;
