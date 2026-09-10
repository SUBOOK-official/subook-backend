-- 격리 테스트 전용: 운영 테이블을 직접 대상으로 실행하지 않는다.
-- 테이블 구조만 복제한 스키마에 migration을 적용한 뒤 public.을 그 스키마로 치환한다.
-- 모든 fixture와 DDL은 테스트가 끝나면 ROLLBACK한다. 운영 알림 트리거는 복제하지 않는다.

do $$
declare
  v_old_request bigint; v_new_request bigint; v_old_shipment bigint; v_new_shipment bigint;
  v_direct_old bigint; v_direct_new bigint; v_result jsonb; v_order bigint; v_book bigint;
  v_legacy_book bigint; v_new_book bigint; v_refunded_book bigint; v_version text;
  v_row record; v_error text;
begin
  -- 활성화 전 접수. 미래의 희망 수거일이어도 기존 정책이다.
  insert into public.pickup_requests(user_id,request_number,pickup_recipient_name,pickup_recipient_phone,
    pickup_postal_code,pickup_address_line1,settlement_bank_name,settlement_account_holder,policy_agreed_at,desired_pickup_date)
  values('00000000-0000-0000-0000-000000000001','FEE-OLD','기존테스트','01000000001','00000','테스트','테스트은행','테스트',now(),current_date+7)
  returning id into v_old_request;
  insert into public.shipments(seller_name,seller_phone,pickup_date)
  values('기존입고테스트','01000000002',current_date+7) returning id into v_direct_old;

  insert into public.pickup_fee_policy_releases(version) values('2026-09');

  -- 옛 번들의 제출은 조용히 인상률을 적용하는 대신 새 동의를 요구한다.
  begin
    insert into public.pickup_requests(user_id,request_number,pickup_recipient_name,pickup_recipient_phone,
      pickup_postal_code,pickup_address_line1,settlement_bank_name,settlement_account_holder,policy_agreed_at)
    values('00000000-0000-0000-0000-000000000001','FEE-STALE','테스트','01000000001','00000','테스트','테스트은행','테스트',now());
    raise exception 'FAIL: stale form accepted';
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_error not like '수수료 정책이 변경되었습니다.%' then raise; end if;
  end;

  perform set_config('subook.pickup_fee_consent','2026-09',true);
  insert into public.pickup_requests(user_id,request_number,pickup_recipient_name,pickup_recipient_phone,
    pickup_postal_code,pickup_address_line1,settlement_bank_name,settlement_account_holder,policy_agreed_at)
  values('00000000-0000-0000-0000-000000000001','FEE-NEW','신규테스트','01000000003','00000','테스트','테스트은행','테스트',now())
  returning id into v_new_request;
  perform set_config('subook.pickup_fee_consent','',true);

  insert into public.shipments(seller_name,seller_phone,pickup_date,pickup_request_id)
  values('기존테스트','01000000001',current_date+7,v_old_request) returning id into v_old_shipment;
  insert into public.shipments(seller_name,seller_phone,pickup_date,pickup_request_id,box_count)
  values('신규테스트','01000000003',current_date+7,v_new_request,1) returning id into v_new_shipment;
  if (select fee_policy_version from public.shipments where id=v_old_shipment) is not null then
    raise exception 'FAIL: old request upgraded on late intake';
  end if;
  if (select fee_policy_version from public.shipments where id=v_new_shipment) is distinct from '2026-09' then
    raise exception 'FAIL: new request policy not inherited';
  end if;
  update public.shipments set pickup_date=current_date+30,box_count=2 where id=v_direct_old;
  if (select fee_policy_version from public.shipments where id=v_direct_old) is not null then
    raise exception 'FAIL: existing shipment upgraded on date change';
  end if;

  -- 서로 다른 정책 병합, 연결, 직접 정책 수정은 거부한다.
  begin
    update public.pickup_requests set merged_into_id=v_old_request where id=v_new_request;
    raise exception 'FAIL: cross-policy merge accepted';
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_error not like '수수료 정책이 다른 수거 신청은%' then raise; end if;
  end;
  begin
    update public.shipments set pickup_request_id=v_new_request where id=v_direct_old;
    raise exception 'FAIL: cross-policy relink accepted';
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_error not like '수수료 정책이 다른 수거 신청에는%' then raise; end if;
  end;
  begin
    update public.shipments set fee_policy_version='2026-09' where id=v_old_shipment;
    raise exception 'FAIL: old policy overwritten';
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_error not like '접수 시 확정된 수수료 정책은%' then raise; end if;
  end;

  -- 직접 등록: 이전 접수는 운영자 지정대로 보존, 신규 확인한 수거만 인상.
  v_result := public.admin_create_direct_shipment_v2('직접기존','01000000004',current_date,null,false);
  if (select fee_policy_version from public.shipments where id=(v_result#>>'{shipment,id}')::bigint) is not null then
    raise exception 'FAIL: backlogged direct intake upgraded';
  end if;
  v_result := public.admin_create_direct_shipment_v2('직접신규','01000000005',current_date,null,true);
  v_direct_new := (v_result#>>'{shipment,id}')::bigint;
  if (select fee_policy_version from public.shipments where id=v_direct_new) is distinct from '2026-09' then
    raise exception 'FAIL: new direct intake missing policy';
  end if;
  begin
    perform public.admin_create_direct_shipment_v2('과거일자','01000000006',current_date-1,null,true);
    raise exception 'FAIL: backdated intake upgraded';
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_error not like '인상 전 수거일에는%' then raise; end if;
  end;

  -- 세 세대 요율 및 정확한 1만원 경계.
  if public.calculate_settlement_fee_percent(9999,date '2026-02-02',null) <> 35
    or public.calculate_settlement_fee_percent(10000,date '2026-02-02',null) <> 30
    or public.calculate_settlement_fee_percent(9999,current_date,null) <> 45
    or public.calculate_settlement_fee_percent(10000,current_date,null) <> 40
    or public.calculate_settlement_fee_percent(9999,current_date,'2026-09') <> 50
    or public.calculate_settlement_fee_percent(10000,current_date,'2026-09') <> 45
    or public.calculate_settlement_fee_percent(10001,current_date,'2026-09') <> 45 then
    raise exception 'FAIL: fee boundary';
  end if;

  insert into public.orders(order_number,status,confirmed_at,shipping_recipient_name,shipping_recipient_phone,shipping_postal_code,shipping_address_line1)
  values('FEE-ORDER','confirmed',now(),'테스트','01000000000','00000','테스트') returning id into v_order;
  insert into public.books(title,shipment_id,price) values('기존정산',v_old_shipment,10000) returning id into v_legacy_book;
  insert into public.books(title,shipment_id,price) values('신규정산',v_new_shipment,10000) returning id into v_new_book;
  insert into public.books(title,shipment_id,price) values('부분환불',v_new_shipment,10000) returning id into v_refunded_book;
  insert into public.order_items(order_id,book_id,title,unit_price,total_price) values
    (v_order,v_legacy_book,'기존정산',10000,10000),(v_order,v_new_book,'신규정산',10000,10000);
  insert into public.order_items(order_id,book_id,title,unit_price,total_price,refunded_at)
  values(v_order,v_refunded_book,'부분환불',10000,10000,now());
  perform public.create_settlements_for_order(v_order);
  select * into v_row from public.settlements where book_id=v_legacy_book;
  if v_row.fee_percent is distinct from 40 or v_row.net_amount is distinct from 6000 then
    raise exception 'FAIL: legacy automatic settlement';
  end if;
  select * into v_row from public.settlements where book_id=v_new_book;
  if v_row.fee_percent is distinct from 45 or v_row.fee_amount is distinct from 4500
    or v_row.box_cost_deducted is distinct from 5000 or v_row.net_amount is distinct from 500 then
    raise exception 'FAIL: new automatic settlement or box deduction';
  end if;
  if exists(select 1 from public.settlements where book_id=v_refunded_book) then
    raise exception 'FAIL: refunded item settled';
  end if;
  perform public.create_settlements_for_order(v_order);
  if (select count(*) from public.settlements where order_id=v_order) <> 2
    or (select box_cost_charged from public.shipments where id=v_new_shipment) <> 5000 then
    raise exception 'FAIL: repeated settlement or box deduction';
  end if;

  -- 수동 정산도 같은 스냅샷. 이미 지급된 자동 정산은 계속 skip한다.
  insert into public.books(title,shipment_id,price) values('신규수동',v_direct_new,9000) returning id into v_book;
  perform public.admin_commit_manual_settlement(jsonb_build_array(jsonb_build_object('book_id',v_book,'sale_amount',9000)),false);
  select * into v_row from public.manual_settlements where book_id=v_book;
  if v_row.fee_percent is distinct from 50 or v_row.net_amount is distinct from 4500 then
    raise exception 'FAIL: manual new policy';
  end if;
  update public.settlements set status='completed',completed_at=now() where book_id=v_legacy_book;
  v_result := public.admin_commit_manual_settlement(jsonb_build_array(jsonb_build_object('book_id',v_legacy_book,'sale_amount',10000)),false);
  if (v_result->>'skipped_auto_settled_count')::integer <> 1 then
    raise exception 'FAIL: paid settlement guard lost';
  end if;
  select fee_policy_version into v_version from public.lookup_seller_shipment_v2('직접신규','01000000005');
  if v_version is distinct from '2026-09' then raise exception 'FAIL: legacy lookup missing policy'; end if;

  if has_table_privilege('anon','public.pickup_fee_policy_releases','SELECT')
    or has_table_privilege('authenticated','public.pickup_fee_policy_releases','INSERT')
    or has_function_privilege('anon','public.admin_create_direct_shipment_v2(text,text,date,uuid,boolean)','EXECUTE') then
    raise exception 'FAIL: policy or admin permissions exposed';
  end if;
  perform set_config('fee_test.admin','false',true);
  begin
    perform public.admin_create_direct_shipment_v2('권한없음','01000000008',current_date,null,true);
    raise exception 'FAIL: non-admin direct intake accepted';
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_error <> 'Admin access required' then raise; end if;
  end;
end;
$$;
