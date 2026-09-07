-- 전용 테스트 스키마에서 migration과 함께 실행. runner가 public 참조를 테스트 스키마로 바꾼다.
insert into delivery_test_20260908.orders(id,user_id,order_number,status,shipping_recipient_name,shipping_recipient_phone,
  shipping_postal_code,shipping_address_line1,shipping_address_line2)
select id,'11111111-1111-1111-1111-111111111111','TEST-'||id,'preparing','테스트','010-1234-5678',
  '12345','서울 테스트로 10','101호' from generate_series(1,14) id;
insert into delivery_test_20260908.order_items(id,order_id,quantity) select id,id,1 from generate_series(1,14) id;
update delivery_test_20260908.orders set shipping_recipient_phone='01012345678',shipping_address_line1=' 서울  테스트로 10 ' where id=2;
update delivery_test_20260908.orders set user_id='22222222-2222-2222-2222-222222222222' where id=3;
update delivery_test_20260908.orders set shipping_address_line2='102호' where id=4;
update delivery_test_20260908.orders set shipping_recipient_name='다른사람' where id=5;
update delivery_test_20260908.orders set shipping_recipient_phone='01000000000' where id=6;
update delivery_test_20260908.orders set shipping_postal_code='99999' where id=7;
update delivery_test_20260908.orders set user_id=null where id in(8,9);
update delivery_test_20260908.orders set status='pending' where id=10;
update delivery_test_20260908.orders set status='shipping',tracking_number='123456789000' where id=11;
update delivery_test_20260908.orders set refund_requested_at=now() where id=12;
update delivery_test_20260908.orders set shipping_address_line2='201호' where id in(13,14);
update delivery_test_20260908.order_items set refunded_at=now() where id=14;

do $$
declare g jsonb; g2 jsonb; blocked boolean; planned jsonb;
begin
  planned:=delivery_test_20260908.admin_plan_order_deliveries(array[1]::bigint[]);
  assert planned='[[1,2]]'::jsonb,'다른 구매자/수취인/연락처/주소/상태/환불 요청은 제외해야 함';
  assert delivery_test_20260908.admin_plan_order_deliveries(array[8,9]::bigint[])='[[8],[9]]'::jsonb,'비회원 식별 불가 → 별도 박스';
  assert not has_function_privilege('anon','delivery_test_20260908.admin_claim_order_delivery(bigint[])','EXECUTE');
  assert not has_function_privilege('authenticated','delivery_test_20260908.admin_transition_order_delivery(uuid,uuid,text,text,jsonb)','EXECUTE');
  assert (select relrowsecurity from pg_class where oid='delivery_test_20260908.order_delivery_groups'::regclass);

  blocked:=false;
  begin perform delivery_test_20260908.admin_claim_order_delivery(array[3,4]::bigint[]); exception when others then blocked:=true; end;
  assert blocked,'서버가 이종 배송지 병합을 차단해야 함';
  blocked:=false;
  begin perform delivery_test_20260908.admin_claim_order_delivery(array[13,14]::bigint[]); exception when others then blocked:=true; end;
  assert blocked,'전품목 환불 주문 발송 금지';

  g:=delivery_test_20260908.admin_claim_order_delivery(array[1,2]::bigint[]);
  blocked:=false;
  begin perform delivery_test_20260908.admin_claim_order_delivery(array[2]::bigint[]); exception when others then blocked:=true; end;
  assert blocked,'다른 주문 클릭으로 중복 예약 금지';
  blocked:=false;
  begin update delivery_test_20260908.orders set status='cancelled' where id=1; exception when others then blocked:=true; end;
  assert blocked,'진행 중 주문 취소 금지';
  blocked:=false;
  begin update delivery_test_20260908.order_items set refunded_at=now() where order_id=2; exception when others then blocked:=true; end;
  assert blocked,'진행 중 품목 환불 금지';
  blocked:=false;
  begin perform delivery_test_20260908.admin_transition_order_delivery((g->>'id')::uuid,gen_random_uuid(),'booking','123456789012');
    exception when others then blocked:=true; end;
  assert blocked,'작업 소유권 검증';

  perform delivery_test_20260908.admin_transition_order_delivery((g->>'id')::uuid,(g->>'claim_token')::uuid,'booking','123456789012','{"clsfCd":"2T01"}');
  blocked:=false;
  begin perform delivery_test_20260908.admin_transition_order_delivery((g->>'id')::uuid,(g->>'claim_token')::uuid,'failed');
    exception when others then blocked:=true; end;
  assert blocked,'CJ 응답 유실 시 자동 재발급 금지';
  perform delivery_test_20260908.admin_transition_order_delivery((g->>'id')::uuid,(g->>'claim_token')::uuid,'registered');
  perform delivery_test_20260908.admin_transition_order_delivery((g->>'id')::uuid,(g->>'claim_token')::uuid,'registered');
  assert (select count(*)=2 from delivery_test_20260908.orders where status='shipping' and tracking_number='123456789012');
  g2:=delivery_test_20260908.admin_claim_order_delivery(array[2]::bigint[]);
  assert g2->>'id'=g->>'id' and g2->>'state'='registered','응답 유실 재시도에서 기존 그룹 반환';

  g:=delivery_test_20260908.admin_claim_order_delivery(array[3]::bigint[]);
  perform delivery_test_20260908.admin_transition_order_delivery((g->>'id')::uuid,(g->>'claim_token')::uuid,'failed');
  g2:=delivery_test_20260908.admin_claim_order_delivery(array[3]::bigint[]);
  assert g2->>'id'<>g->>'id','CJ 접수 전 실패는 재시도 가능';
  update delivery_test_20260908.order_delivery_groups set updated_at=now()-interval '11 minutes' where id=(g2->>'id')::uuid;
  g:=delivery_test_20260908.admin_claim_order_delivery(array[3]::bigint[]);
  assert g->>'id'<>g2->>'id','접수 전 죽은 작업 회수';
  blocked:=false;
  begin perform delivery_test_20260908.admin_transition_order_delivery((g2->>'id')::uuid,(g2->>'claim_token')::uuid,'booking','123456789099');
    exception when others then blocked:=true; end;
  assert blocked,'회수된 작업의 뒤늦은 CJ 접수 차단';
end;
$$;
