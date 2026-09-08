-- 새 collection migration 적용 후 실행한다. 실제 shipment 1건이 필요하다.
-- 테스트 상품은 숨김이며 최종 ROLLBACK으로 재고·상품·영수증 변경을 남기지 않는다.
begin;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claim.sub','',true);

do $test$
declare
  sid bigint; base_item jsonb; groups jsonb; changed jsonb; variants jsonb;
  result jsonb; again jsonb; metadata jsonb; legacy_result jsonb;
  key uuid:=gen_random_uuid(); first_key uuid:=gen_random_uuid(); second_key uuid:=gen_random_uuid();
  third_key uuid:=gen_random_uuid(); legacy_key uuid:=gen_random_uuid();
  before_books integer; before_products integer; before_receipts integer;
  v_product_id bigint; new_item jsonb; suffix text:=gen_random_uuid()::text;
begin
  select id into sid from public.shipments order by id limit 1;
  if sid is null then raise exception '검증할 수거 건이 없습니다.'; end if;
  if exists(select 1 from public.books where serial_number between 2146000001 and 2146000999) then
    raise exception '테스트 전용 일련번호 범위를 다른 빈 범위로 바꾸세요.';
  end if;
  base_item:=jsonb_build_object('title','2027 기타 검증 '||suffix||' 국어','subject','국어','subject_detail',null,
    'brand','기타','book_type','모의고사','published_year',2027,'condition_grade','S',
    'writing_percentage',0,'has_damage',false,'components_confirmed',true,'price',12000,
    'original_price',null,'location','TEST','serial_number',2146000001,'is_public',false,
    'cover_image_url','https://example.invalid/collection-cover.jpg',
    'inspection_image_urls',jsonb_build_array('https://example.invalid/collection-detail.jpg'));
  variants:=jsonb_build_array(jsonb_build_object('option','01. 함수','quantity',1),
    jsonb_build_object('option','02. 도함수','quantity',2,'price',8000,'condition_grade','A_PLUS','writing_percentage',2,'has_damage',true));
  groups:=jsonb_build_array(
    jsonb_build_object('request_key',first_key,'kind','single','item',base_item),
    jsonb_build_object('request_key',second_key,'kind','batch','item',base_item||jsonb_build_object(
      'title','2027 기타 검증 '||suffix||' 미적분','subject','수학','subject_detail','미적분','serial_number',2146000002),'variants',variants),
    jsonb_build_object('request_key',third_key,'kind','single','item',base_item||jsonb_build_object(
      'title','2028 기타 검증 '||suffix||' 미적분Ⅰ','subject','수학','subject_detail','미적분Ⅰ',
      'published_year',2028,'serial_number',2146000005))
  );
  select count(*) into before_books from public.books;
  result:=public.admin_register_intake_collection(sid,key,groups);
  again:=public.admin_register_intake_collection(sid,key,groups);
  if (result->>'collection')::boolean is not true or (result->>'group_count')::integer<>3
    or (result->>'book_count')::integer<>5 or jsonb_array_length(result->'groups')<>3 then
    raise exception 'Collection result/count failed';
  end if;
  if result is distinct from (again-'replayed') or (again->>'replayed')::boolean is not true
    or (select count(*) from public.books)<>before_books+5 then raise exception 'Collection replay created duplicates'; end if;
  if result->'groups'->0->>'request_key'<>first_key::text or result->'groups'->1->>'request_key'<>second_key::text then
    raise exception 'Group result mapping failed';
  end if;
  if not exists(select 1 from public.books b join public.products p on p.id=b.product_id
    where b.id=(result->'groups'->0->>'book_id')::bigint and b.subject='국어' and b.subject_detail is null
      and p.subject_detail is null and b.title=base_item->>'title') then raise exception 'Unselected detail must remain NULL'; end if;
  v_product_id:=(result->'groups'->1->>'product_id')::bigint;
  if (select count(*) from public.books b where b.product_id=v_product_id and b.subject='수학' and b.subject_detail='미적분'
      and b.cover_image_url=base_item->>'cover_image_url' and b.inspection_image_urls=ARRAY['https://example.invalid/collection-detail.jpg'])<>3
    or not exists(select 1 from public.products p where p.id=v_product_id and p.subject_detail='미적분') then
    raise exception 'Batch detail/shared photos failed';
  end if;
  if (select count(*) from public.books b where b.product_id=v_product_id and b.option='02. 도함수'
    and b.price=8000 and b.condition_grade='A_PLUS' and b.writing_percentage=2 and b.has_damage)<>2 then
    raise exception 'Batch variant overrides failed';
  end if;
  if not exists(select 1 from public.books b where b.id=(result->'groups'->2->>'book_id')::bigint and b.subject_detail='미적분Ⅰ') then
    raise exception 'New curriculum detail was renamed';
  end if;
  metadata:=public.admin_intake_catalog_metadata(array[(result->'groups'->0->>'product_id')::bigint,v_product_id]);
  if jsonb_array_length(metadata)<>2 or not exists(select 1 from jsonb_array_elements(metadata) m
    where (m->>'product_id')::bigint=v_product_id and m->>'subject_detail'='미적분') then raise exception 'Catalog metadata failed'; end if;
  if public.admin_intake_catalog_metadata(null)<>'[]'::jsonb then raise exception 'Empty metadata failed'; end if;
  -- 기존 단권/배치 pending payload의 키가 없는 형태도 그대로 재시도할 수 있어야 한다.
  new_item:=(base_item-'subject_detail')||jsonb_build_object('title','2027 기타 기존형식 '||suffix||' 수학',
    'subject','수학','serial_number',2146000010);
  legacy_result:=public.admin_register_intake_book(sid,legacy_key,new_item);
  again:=public.admin_register_intake_book(sid,legacy_key,new_item);
  if legacy_result is distinct from (again-'replayed') then raise exception 'Legacy single retry changed'; end if;
  legacy_key:=gen_random_uuid();
  new_item:=new_item||jsonb_build_object('serial_number',2146000020);
  legacy_result:=public.admin_register_intake_batch(sid,legacy_key,new_item,variants);
  again:=public.admin_register_intake_batch(sid,legacy_key,new_item,variants);
  if legacy_result is distinct from (again-'replayed') then raise exception 'Legacy batch retry changed'; end if;
  -- 카탈로그 선택 시 새 화면에 잘못 남은 detail/null로 기존 마스터를 덮어쓰면 안 된다.
  legacy_result:=public.admin_register_intake_book(sid,gen_random_uuid(),base_item||jsonb_build_object(
    'product_id',v_product_id,'subject_detail',null,'serial_number',2146000030));
  if not exists(select 1 from public.books b where b.id=(legacy_result->>'book_id')::bigint
      and b.subject='수학' and b.subject_detail='미적분') then raise exception 'Existing catalog detail was lost'; end if;
  perform public.refresh_storefront_product_status(v_product_id);
  if not exists(select 1 from public.products p where p.id=v_product_id and p.subject_detail='미적분') then
    raise exception 'Catalog refresh erased detail';
  end if;
  -- 기존 마스터 수정 RPC는 하위 과목 인자가 없다. 상위 유지 시 보존, 상위 변경 시 정리한다.
  perform public.admin_update_product_master(v_product_id,(select p.title from public.products p where p.id=v_product_id),
    p_subject=>'수학');
  if not exists(select 1 from public.products p where p.id=v_product_id and p.subject_detail='미적분')
    or exists(select 1 from public.books b where b.product_id=v_product_id and b.subject_detail is distinct from '미적분') then
    raise exception 'Unchanged parent subject erased detail';
  end if;
  perform public.admin_update_product_master(v_product_id,(select p.title from public.products p where p.id=v_product_id),
    p_subject=>'영어');
  if not exists(select 1 from public.products p where p.id=v_product_id and p.subject='영어' and p.subject_detail is null)
    or exists(select 1 from public.books b where b.product_id=v_product_id and (b.subject<>'영어' or b.subject_detail is not null)) then
    raise exception 'Legacy master edit retained incompatible detail';
  end if;
  -- 새 상위/하위 과목을 동시에 명시하는 업데이트는 새 값을 지우지 않는다.
  update public.books b set subject='수학',subject_detail='미적분' where b.product_id=v_product_id;
  update public.products p set subject='수학',subject_detail='미적분' where p.id=v_product_id;
  if not exists(select 1 from public.products p where p.id=v_product_id and p.subject_detail='미적분')
    or exists(select 1 from public.books b where b.product_id=v_product_id and b.subject_detail is distinct from '미적분') then
    raise exception 'Explicit new subject/detail pair was erased';
  end if;
  -- 두 테이블의 직접 상위 변경 경로도 기존 값을 정리해야 한다.
  update public.products p set subject='기타' where p.id=v_product_id;
  update public.books b set subject='기타' where b.product_id=v_product_id;
  if not exists(select 1 from public.products p where p.id=v_product_id and p.subject='기타' and p.subject_detail is null)
    or exists(select 1 from public.books b where b.product_id=v_product_id and (b.subject<>'기타' or b.subject_detail is not null)) then
    raise exception 'Direct parent subject edit retained incompatible detail';
  end if;

  select count(*) into before_books from public.books;
  select count(*) into before_products from public.products;
  select count(*) into before_receipts from public.admin_intake_receipts;
  changed:=jsonb_set(groups,'{0,item,price}','13000'::jsonb);
  begin
    perform public.admin_register_intake_collection(sid,key,changed);
    raise exception 'Changed collection payload accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_collection(sid+1,key,groups);
    raise exception 'Changed shipment accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  -- 첫 교재 저장 후 두 번째 가격 오류: 상품·권·하위/상위 영수증까지 모두 없어야 한다.
  changed:=jsonb_build_array(
    jsonb_build_object('request_key',gen_random_uuid(),'kind','single','item',base_item||jsonb_build_object(
      'title','2027 기타 롤백 '||suffix||' 국어','serial_number',2146000100)),
    jsonb_build_object('request_key',gen_random_uuid(),'kind','batch','item',base_item||jsonb_build_object(
      'serial_number',2146000101),'variants',jsonb_build_array(jsonb_build_object('option','오류','quantity',1,'price',-1)))
  );
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),changed);
    raise exception 'Invalid second group accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  if (select count(*) from public.books)<>before_books or (select count(*) from public.products)<>before_products
    or (select count(*) from public.admin_intake_receipts)<>before_receipts then raise exception 'Partial collection persisted'; end if;
  -- 기존 그룹 키를 내용만 바꿔 재사용해도 앞의 새 교재까지 롤백된다.
  changed:=jsonb_build_array(changed->0,jsonb_set(groups->1,'{item,price}','13000'::jsonb));
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),changed);
    raise exception 'Changed child payload accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  if (select count(*) from public.books)<>before_books or (select count(*) from public.products)<>before_products
    or (select count(*) from public.admin_intake_receipts)<>before_receipts then raise exception 'Child conflict rollback failed'; end if;
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),jsonb_build_array(groups->0,groups->0));
    raise exception 'Duplicate group keys accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_collection(sid,first_key,jsonb_build_array(groups->0));
    raise exception 'Collection/child key collision accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),jsonb_set(groups,'{0,request_key}','"invalid-key"'::jsonb));
    raise exception 'Invalid group UUID accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),'[]'::jsonb);
    raise exception 'Empty collection accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),
      (select jsonb_agg(jsonb_build_object('request_key',gen_random_uuid(),'kind','single','item',base_item)) from generate_series(1,101)));
    raise exception '101 groups accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),jsonb_build_array(
      jsonb_build_object('request_key',gen_random_uuid(),'kind','batch','item',base_item,'variants',
        jsonb_build_array(jsonb_build_object('option','1','quantity',100),jsonb_build_object('option','2','quantity',100),
          jsonb_build_object('option','3','quantity',100))),
      jsonb_build_object('request_key',gen_random_uuid(),'kind','single','item',base_item)));
    raise exception '301 books accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  -- 인증된 일반 회원, 익명 모두 새 읽기/등록 RPC에 접근할 수 없어야 한다.
  perform set_config('request.jwt.claim.role','authenticated',true);
  begin
    perform public.admin_register_intake_collection(sid,gen_random_uuid(),groups);
    raise exception 'Non-admin collection access allowed' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_intake_catalog_metadata(array[v_product_id]);
    raise exception 'Non-admin metadata access allowed' using errcode='XX999';
  exception when raise_exception then null; end;
  perform set_config('request.jwt.claim.role','anon',true);
  begin
    perform public.admin_register_intake_collection(sid,key,groups);
    raise exception 'Anonymous replay access allowed' using errcode='XX999';
  exception when raise_exception then null; end;
  if has_function_privilege('anon','public.admin_register_intake_collection(bigint,uuid,jsonb)','EXECUTE')
    or has_function_privilege('anon','public.admin_intake_catalog_metadata(bigint[])','EXECUTE') then
    raise exception 'Anonymous execute grant allowed';
  end if;
  if not has_function_privilege('authenticated','public.admin_register_intake_collection(bigint,uuid,jsonb)','EXECUTE')
    or not has_function_privilege('service_role','public.admin_register_intake_collection(bigint,uuid,jsonb)','EXECUTE') then
    raise exception 'Expected RPC grants missing';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.admin_intake_receipts'::regclass) then
    raise exception 'Receipt RLS is disabled';
  end if;
end;
$test$;
select 'PASS: mixed collection, optional detail, curriculum names, catalog preservation, legacy/direct subject edits, explicit new detail, photo/option sharing, legacy retry, exact replay, atomic rollback, key/quantity bounds, admin guard and grants (rolled back)' as verification;
rollback;
