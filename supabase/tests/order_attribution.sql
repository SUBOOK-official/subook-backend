-- BEGIN/ROLLBACK 안에서 실행. 합성 주문과 문맥은 모두 롤백한다.
begin;

do $test$
declare
  v_number text := 'ATTR-TEST-' || upper(substr(md5(gen_random_uuid()::text), 1, 16));
  v_order_id bigint;
  v_result jsonb;
  v_attribution jsonb := jsonb_build_object(
    'version', 1,
    'first_touch', jsonb_build_object(
      'source', 'instagram', 'medium', 'cpc', 'campaign', 'fall_sale',
      'click_id_types', jsonb_build_array('fbclid', 'raw-secret'),
      'referrer_host', 'L.INSTAGRAM.COM', 'landing_path', '/store/10',
      'captured_at', '2026-09-12T07:00:00.000Z', 'gclid', 'MUST_NOT_PERSIST'
    ),
    'last_touch', jsonb_build_object(
      'source', 'naver', 'medium', 'organic', 'landing_path', '/',
      'captured_at', '2026-09-12T07:30:00.000Z'
    ),
    'unknown_top_level', 'MUST_NOT_PERSIST'
  );
begin
  if has_table_privilege('anon', 'public.order_attribution_contexts', 'SELECT')
     or has_table_privilege('authenticated', 'public.order_attribution_attempts', 'SELECT')
     or has_function_privilege('anon', 'public.get_admin_order_attributions(bigint[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.sanitize_order_attribution(jsonb)', 'EXECUTE') then
    raise exception 'Attribution permissions too broad';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.order_attribution_contexts'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.order_attribution_attempts'::regclass) then
    raise exception 'Attribution RLS missing';
  end if;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config(
    'request.headers',
    '{"origin":"https://subook.kr","user-agent":"Subook attribution rollback test","x-forwarded-for":"192.0.2.20"}',
    true
  );

  -- 주문 전 카드 세션에 문맥을 붙이고, 실제 주문 INSERT에서 자동 복사한다.
  insert into public.pg_checkout_sessions(order_number, user_id, payload, expected_amount, created_at)
  values (v_number, null, '{"shipping_recipient_phone":"01000000000"}', 59000, clock_timestamp());
  v_result := public.attach_order_attribution_context(v_number, '01000000000', v_attribution);
  if v_result->>'recorded' <> 'true' then raise exception 'Valid guest attribution rejected'; end if;
  if (select attribution#>>'{first_touch,source}' from public.order_attribution_contexts where order_number = v_number) <> 'instagram' then
    raise exception 'Checkout attribution not stored';
  end if;

  insert into public.orders(
    order_number, payment_method, shipping_recipient_name, shipping_recipient_phone,
    shipping_postal_code, shipping_address_line1, total_amount, subtotal, item_count,
    guest_terms_agreed_at, created_at
  ) values (
    v_number, 'card', '검증전용', '01000000000', '00000', '롤백 테스트',
    59000, 59000, 1, clock_timestamp(), clock_timestamp()
  ) returning id into v_order_id;

  if (select attribution#>>'{first_touch,source}' from public.orders where id = v_order_id) <> 'instagram'
     or (select attribution#>>'{first_touch,referrer_host}' from public.orders where id = v_order_id) <> 'l.instagram.com'
     or (select attribution#>>'{first_touch,click_id_types,0}' from public.orders where id = v_order_id) <> 'fbclid'
     or (select attribution::text from public.orders where id = v_order_id) like '%MUST_NOT_PERSIST%'
     or exists(select 1 from public.order_attribution_contexts where order_number = v_number) then
    raise exception 'Order attribution transfer or sanitization failed';
  end if;

  -- 잘못된 게스트 인증과 개발 origin은 거절한다.
  insert into public.orders(
    order_number, payment_method, shipping_recipient_name, shipping_recipient_phone,
    shipping_postal_code, shipping_address_line1, total_amount, subtotal, item_count,
    guest_terms_agreed_at, created_at
  ) values (
    v_number || '-LATE', 'card', '검증전용', '01000000000', '00000', '롤백 테스트',
    10000, 10000, 1, clock_timestamp(), clock_timestamp()
  );
  if public.attach_order_attribution_context(v_number || '-LATE', '01000000000', v_attribution)->>'recorded' <> 'true'
     or (select attribution#>>'{last_touch,source}' from public.orders where order_number = v_number || '-LATE') <> 'naver' then
    raise exception 'Existing order attribution not attached';
  end if;
  if public.attach_order_attribution_context(v_number || '-LATE', '01011111111', v_attribution)->>'recorded' <> 'false' then
    raise exception 'Wrong guest phone accepted';
  end if;
  perform set_config('request.headers', '{"origin":"http://localhost:5183","x-forwarded-for":"192.0.2.20"}', true);
  if public.attach_order_attribution_context(v_number || '-LATE', '01000000000', v_attribution)->>'recorded' <> 'false' then
    raise exception 'Development origin accepted';
  end if;
end;
$test$;

select 'RLS, ownership, card handoff, late attach, sanitization, click-id minimization' as verified;
rollback;
