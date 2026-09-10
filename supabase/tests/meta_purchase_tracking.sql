-- 반드시 BEGIN/ROLLBACK 안에서 실행. 새 HTTP 전송 함수는 아래 테스트 대역으로 교체.
-- 테스트의 주문/입금/토큰/크론은 모두 롤백하며 실제 구매 이벤트를 만들지 않는다.
create or replace function public.meta_purchase_http(p_payload jsonb,p_token text)
returns jsonb language plpgsql security definer set search_path='' as $mock$
begin
  perform set_config('subook.meta_test_last_event_id',p_payload->>'event_id',true);
  return current_setting('subook.meta_test_http_result',true)::jsonb;
end;
$mock$;
do $test$
declare
  v_id bigint;
  v_old_id bigint;
  v_late_id bigint;
  v_book bigint;
  v_member uuid;
  v_number text := 'META-TEST-'||upper(substr(md5(gen_random_uuid()::text),1,16));
  v_result jsonb;
  v_payload jsonb;
  v_event_id text;
  v_time timestamptz;
  v_profile record;
  v_member_order bigint;
begin
  if has_table_privilege('anon','public.meta_checkout_contexts','SELECT')
     or has_table_privilege('authenticated','public.meta_purchase_outbox','SELECT')
     or has_function_privilege('anon','public.meta_purchase_http(jsonb,text)','EXECUTE')
     or has_function_privilege('anon','public.meta_purchase_sweep()','EXECUTE')
     or has_function_privilege('authenticated','public.meta_enqueue_purchase(bigint)','EXECUTE') then
    raise exception 'Meta server data or token permissions too broad';
  end if;
  if (select count(*) from pg_class where oid in ('public.meta_tracking_config'::regclass,
      'public.meta_checkout_contexts'::regclass,'public.meta_checkout_attempts'::regclass,
      'public.meta_purchase_outbox'::regclass) and relrowsecurity)<>4 then
    raise exception 'Meta RLS missing';
  end if;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  perform set_config('request.headers','{"origin":"https://subook.kr","user-agent":"Subook SQL rollback test","x-forwarded-for":"192.0.2.10"}',true);
  select id into v_book from public.books where product_id=2370 order by id limit 1;
  if v_book is null then raise exception 'Test requires existing catalog product 2370'; end if;
  insert into public.orders(order_number,status,payment_status,payment_method,
    shipping_recipient_name,shipping_recipient_phone,shipping_postal_code,shipping_address_line1,
    total_amount,subtotal,item_count,guest_terms_agreed_at,created_at)
  values(v_number,'pending','pending','bank_transfer','검증전용','010-0000-0000','00000','롤백 테스트',
    59000,59000,1,clock_timestamp(),clock_timestamp()) returning id into v_id;
  insert into public.order_items(order_id,book_id,product_id,title,quantity,unit_price,total_price)
    values(v_id,v_book,2370,'검증전용',1,59000,59000);

  -- 비회원 인증 실패, 개발 출처, 올바른 문맥, 재호출 불변.
  v_result:=public.attach_meta_checkout_context(v_number,'01011111111','fb.1.1789000000000.123',null);
  if v_result->>'recorded'<>'false' then raise exception 'Wrong guest phone accepted'; end if;
  perform set_config('request.headers','{"origin":"http://localhost:5183","user-agent":"test"}',true);
  v_result:=public.attach_meta_checkout_context(v_number,'01000000000',null,null);
  if v_result->>'recorded'<>'false' then raise exception 'Development context accepted'; end if;
  perform set_config('request.headers','{"origin":"https://subook.kr","user-agent":"Subook SQL rollback test","x-forwarded-for":"192.0.2.10, proxy"}',true);
  v_result:=public.attach_meta_checkout_context(v_number,'01000000000','fb.1.1789000000000.123','fb.1.1789000000000.click_123');
  if v_result->>'recorded'<>'true' then raise exception 'Valid guest context rejected'; end if;
  perform public.attach_meta_checkout_context(v_number,'01000000000','fb.1.1789000000000.999',null);
  if (select fbp from public.meta_checkout_contexts where order_number=v_number)<>'fb.1.1789000000000.123' then
    raise exception 'Context was overwritten on retry';
  end if;
  if exists(select 1 from public.meta_purchase_outbox where order_id=v_id) then raise exception 'Unpaid order tracked'; end if;

  -- 실제 결제 상태 전이 1회만 큐에 적재, 환불/재처리 시 이미 기록한 이벤트 유지.
  update public.orders set payment_status='paid' where id=v_id;
  select payload,event_id,event_time into v_payload,v_event_id,v_time from public.meta_purchase_outbox where order_id=v_id;
  if v_payload is null or v_payload->>'event_name'<>'Purchase'
     or v_payload#>>'{custom_data,value}'<>'59000' or v_payload#>>'{custom_data,currency}'<>'KRW'
     or v_payload#>>'{custom_data,content_ids,0}'<>'gxav9zwrza'
     or v_payload#>>'{custom_data,contents,0,quantity}'<>'1'
     or v_payload#>>'{user_data,client_ip_address}'<>'192.0.2.10'
     or v_payload#>>'{user_data,fbp}'<>'fb.1.1789000000000.123' then raise exception 'Purchase payload invalid'; end if;
  if v_payload#>'{user_data,em}' is not null or v_payload#>'{user_data,ph}' is not null
     or v_payload::text like '%010-0000-0000%' or v_payload::text like '%롤백 테스트%' then
    raise exception 'Guest recipient contact/address leaked';
  end if;
  update public.orders set payment_status='refunded' where id=v_id;
  update public.orders set payment_status='paid' where id=v_id;
  perform public.meta_enqueue_purchase(v_id);
  if (select count(*) from public.meta_purchase_outbox where order_id=v_id)<>1
     or (select event_id from public.meta_purchase_outbox where order_id=v_id)<>v_event_id
     or (select event_time from public.meta_purchase_outbox where order_id=v_id)<>v_time then
    raise exception 'Purchase deduplication failed';
  end if;

  -- 구 주문은 새 문맥을 등록해 소급할 수 없다.
  insert into public.orders(order_number,shipping_recipient_name,shipping_recipient_phone,
    shipping_postal_code,shipping_address_line1,guest_terms_agreed_at,created_at)
  values(v_number||'-OLD','검증전용','01000000000','00000','롤백 테스트',clock_timestamp(),
    (select installed_at-interval '1 day' from public.meta_tracking_config)) returning id into v_old_id;
  if public.attach_meta_checkout_context(v_number||'-OLD','01000000000',null,null)->>'recorded'<>'false' then
    raise exception 'Legacy order enrolled';
  end if;

  -- 카드 세션(created)도 주문 실체 생성 전 문맥 등록 가능.
  insert into public.pg_checkout_sessions(order_number,user_id,payload,expected_amount,created_at)
    values(v_number||'-PG',null,'{"shipping_recipient_phone":"01000000000"}',59000,clock_timestamp());
  if public.attach_meta_checkout_context(v_number||'-PG','01000000000',null,null)->>'recorded'<>'true' then
    raise exception 'Card checkout session context rejected';
  end if;
  if exists(select 1 from public.meta_purchase_outbox q join public.orders o on o.id=q.order_id where o.order_number=v_number||'-PG') then
    raise exception 'Unpaid card checkout tracked';
  end if;

  -- 결제 완료가 먼저일 때 문맥이 늦게 도착해도 복구.
  insert into public.orders(order_number,payment_method,shipping_recipient_name,shipping_recipient_phone,
    shipping_postal_code,shipping_address_line1,total_amount,guest_terms_agreed_at,created_at)
  values(v_number||'-LATE','card','검증전용','01000000000','00000','롤백 테스트',59000,clock_timestamp(),clock_timestamp()) returning id into v_late_id;
  insert into public.order_items(order_id,book_id,product_id,title,quantity,unit_price,total_price)
    values(v_late_id,v_book,2370,'검증전용',1,59000,59000);
  update public.orders set payment_status='paid' where id=v_late_id;
  if exists(select 1 from public.meta_purchase_outbox where order_id=v_late_id) then raise exception 'Contextless legacy path tracked'; end if;
  v_result:=public.attach_meta_checkout_context(v_number||'-LATE','01000000000',null,null);
  if v_result->>'recorded'<>'true'
     or not exists(select 1 from public.meta_purchase_outbox where order_id=v_late_id) then raise exception 'Late context recovery failed'; end if;

  -- 회원 소유권 검증. 회원 정보는 읽기만 하고 원문을 출력/전송하지 않는다.
  select user_id into v_member from public.member_profiles where terms_agreed_at is not null limit 1;
  if v_member is null then raise exception 'Test requires a terms-agreed member'; end if;
  insert into public.pg_checkout_sessions(order_number,user_id,payload,expected_amount,created_at)
    values(v_number||'-MEMBER',v_member,'{"shipping_recipient_phone":"01000000000"}',59000,clock_timestamp());
  if public.attach_meta_checkout_context(v_number||'-MEMBER','01000000000',null,null)->>'recorded'<>'false' then
    raise exception 'Guest attached member order'; end if;
  perform set_config('request.jwt.claim.sub',v_member::text,true);
  if public.attach_meta_checkout_context(v_number||'-MEMBER',null,null,null)->>'recorded'<>'true' then
    raise exception 'Owner context rejected'; end if;
  perform set_config('request.jwt.claim.sub','',true);

  -- 기존 회원의 연락처/동의는 읽기만 하고, 합성 주문의 서버 해시만 검사한다.
  for v_profile in
    select distinct on (marketing_opt_in) user_id,email,marketing_opt_in
    from public.member_profiles where terms_agreed_at is not null
      and not coalesce(is_blocked,false) and personal_data_erased_at is null
      and withdrawal_requested_at is null and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    order by marketing_opt_in,user_id
  loop
    insert into public.orders(order_number,user_id,payment_method,shipping_recipient_name,shipping_recipient_phone,
      shipping_postal_code,shipping_address_line1,total_amount,created_at)
    values(v_number||'-CONSENT-'||upper(v_profile.marketing_opt_in::text),v_profile.user_id,'card','검증전용','01000000000',
      '00000','롤백 테스트',59000,clock_timestamp()) returning id into v_member_order;
    insert into public.order_items(order_id,book_id,product_id,title,quantity,unit_price,total_price)
      values(v_member_order,v_book,2370,'검증전용',1,59000,59000);
    perform set_config('request.jwt.claim.sub',v_profile.user_id::text,true);
    v_result:=public.attach_meta_checkout_context(v_number||'-CONSENT-'||upper(v_profile.marketing_opt_in::text),null,null,null);
    if v_result->>'recorded'<>'true' then raise exception 'Member consent context rejected'; end if;
    update public.orders set payment_status='paid' where id=v_member_order;
    select payload into v_payload from public.meta_purchase_outbox where order_id=v_member_order;
    if v_profile.marketing_opt_in then
      if v_payload#>>'{user_data,em,0}' is distinct from encode(extensions.digest(lower(btrim(v_profile.email)),'sha256'),'hex') then
        raise exception 'Opted-in email hash invalid'; end if;
    elsif v_payload#>'{user_data,em}' is not null or v_payload#>'{user_data,ph}' is not null then
      raise exception 'Non-consenting member contact included';
    end if;
    if v_payload::text like '%'||v_profile.email||'%' then raise exception 'Raw member email included'; end if;
  end loop;
  perform set_config('request.jwt.claim.sub','',true);

  -- 토큰 없음/비활성은 전송하지 않는다.
  perform public.meta_purchase_sweep();
  if (select status from public.meta_purchase_outbox where order_id=v_id)<>'pending' then raise exception 'Disabled sender dispatched'; end if;
  if not exists(select 1 from vault.secrets where name='meta_capi_access_token') then
    perform vault.create_secret('SQL_ROLLBACK_TEST_NOT_A_REAL_TOKEN','meta_capi_access_token');
  end if;
  update public.meta_tracking_config set enabled=true;
  perform set_config('subook.meta_test_http_result','{"http_status":503,"transient":true}',true);
  perform public.meta_purchase_sweep();
  if (select attempts from public.meta_purchase_outbox where order_id=v_id)<>1 then raise exception 'Send attempt failed'; end if;

  -- 503 재시도에서도 원래 시각/ID 유지. 성공 확인 시 페이로드 즉시 제거.
  if (select status from public.meta_purchase_outbox where order_id=v_id)<>'pending' then raise exception 'Transient error not retried'; end if;
  update public.meta_purchase_outbox set next_attempt_at=clock_timestamp() where order_id=v_id;
  perform set_config('subook.meta_test_http_result','{"http_status":200,"events_received":1}',true);
  perform public.meta_purchase_sweep();
  if (select attempts from public.meta_purchase_outbox where order_id=v_id)<>2 then raise exception 'Retry attempt missing'; end if;
  if current_setting('subook.meta_test_last_event_id')<>v_event_id then
    raise exception 'Retry event ID changed'; end if;
  if (select status from public.meta_purchase_outbox where order_id=v_id)<>'confirmed'
     or (select payload from public.meta_purchase_outbox where order_id=v_id) is not null then raise exception 'Success not finalized'; end if;

  -- 영구 오류의 원문에는 비밀이 있어도 코드만 기록.
  update public.meta_purchase_outbox set next_attempt_at=clock_timestamp() where order_id=v_late_id;
  perform set_config('subook.meta_test_http_result','{"http_status":400,"error_code":190,"transient":false,"message":"DO_NOT_LOG_TOKEN_OR_CONTACT"}',true);
  perform public.meta_purchase_sweep();
  if (select status from public.meta_purchase_outbox where order_id=v_late_id)<>'failed'
     or (select last_error from public.meta_purchase_outbox where order_id=v_late_id)<>'http_400_graph_190' then raise exception 'Permanent error handling failed'; end if;
end;
$test$;
select 'permissions, unpaid exclusion, guest/member ownership, dev/legacy exclusion, card session, late context, consent hashes, dedup, retries, success cleanup, error redaction' as verified;
