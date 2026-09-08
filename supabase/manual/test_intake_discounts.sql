-- 관리자 할인 저장·옵션 예외·원자성·구버전 호환. 테스트 데이터는 모두 ROLLBACK.
begin;
select set_config('request.jwt.claim.role','service_role',true);
select set_config('request.jwt.claim.sub','',true);
do $test$
declare
  sid bigint; item jsonb; result jsonb; again jsonb; groups jsonb; changed jsonb;
  key uuid:=gen_random_uuid(); suffix text:=gen_random_uuid()::text;
  before_books integer; before_receipts integer; test_patch jsonb; rejected boolean;
begin
  select id into sid from public.shipments order by id limit 1;
  if sid is null then raise exception '검증할 수거 건이 없습니다.'; end if;
  if exists(select 1 from public.books where serial_number between 2146100001 and 2146100999) then
    raise exception '테스트 일련번호 범위가 이미 사용 중입니다.';
  end if;
  item:=jsonb_build_object('title','2027 기타 할인검증 '||suffix||' 수학','subject','수학','subject_detail',null,
    'brand','기타','book_type','모의고사','published_year',2027,'condition_grade','S',
    'writing_percentage',0,'has_damage',false,'components_confirmed',true,'price',10001,
    'original_price',20001,'discount_type','rate','discount_value',50,'location','TEST',
    'serial_number',2146100001,'is_public',false);
  result:=public.admin_register_intake_book(sid,key,item);
  again:=public.admin_register_intake_book(sid,key,item);
  if result is distinct from again-'replayed' or (again->>'replayed')::boolean is not true then raise exception 'Discount replay failed'; end if;
  if not exists(select 1 from public.books where id=(result->>'book_id')::bigint and price=10001
    and original_price=20001 and discount_type='rate' and discount_value=50) then raise exception 'Rate rounding/save failed'; end if;

  groups:=jsonb_build_array(
    jsonb_build_object('kind','single','request_key',gen_random_uuid(),'item',item||jsonb_build_object(
      'serial_number',2146100002,'original_price',20000,'discount_type','amount','discount_value',9000,'price',11000)),
    jsonb_build_object('kind','batch','request_key',gen_random_uuid(),'item',item||jsonb_build_object(
      'serial_number',2146100003,'original_price',20000,'discount_value',40,'price',12000),
      'variants',jsonb_build_array(jsonb_build_object('option','1회','quantity',2,'price',12000,'discount_type','rate','discount_value',40),
        jsonb_build_object('option','2회','quantity',1,'price',9000,'discount_type','none','discount_value',null,
          'condition_grade','A_PLUS','writing_percentage',2,'has_damage',true)))
  );
  result:=public.admin_register_intake_collection(sid,gen_random_uuid(),groups);
  if (result->>'book_count')::integer<>4 then raise exception 'Collection count failed'; end if;
  if not exists(select 1 from public.books where serial_number=2146100002 and price=11000 and discount_type='amount' and discount_value=9000)
    or (select count(*) from public.books where serial_number in (2146100003,2146100004) and price=12000 and discount_type='rate' and discount_value=40)<>2
    or not exists(select 1 from public.books where serial_number=2146100005 and price=9000 and discount_type='none' and discount_value is null
      and condition_grade='A_PLUS' and writing_percentage=2 and has_damage) then raise exception 'Collection discounts/variant override failed'; end if;

  -- 정가 미상 직접 입력과 할인 0도 보존.
  perform public.admin_register_intake_book(sid,gen_random_uuid(),item||jsonb_build_object(
    'serial_number',2146100006,'original_price',null,'discount_type','none','discount_value',null,'price',11000));
  perform public.admin_register_intake_book(sid,gen_random_uuid(),item||jsonb_build_object(
    'serial_number',2146100007,'discount_value',0,'price',20001));
  if not exists(select 1 from public.books where serial_number=2146100006 and original_price is null and price=11000)
    or not exists(select 1 from public.books where serial_number=2146100007 and discount_type='rate' and discount_value=0 and price=20001) then raise exception 'Unknown retail/zero discount failed'; end if;
  -- 할인 필드 없는 배포 전 payload도 기존 규칙으로 처리.
  perform public.admin_register_intake_book(sid,gen_random_uuid(),(item-'discount_type'-'discount_value')||jsonb_build_object('serial_number',2146100008));
  if not exists(select 1 from public.books where serial_number=2146100008 and discount_type='amount' and discount_value=10000) then raise exception 'Legacy inference failed'; end if;

  select count(*) into before_books from public.books;
  select count(*) into before_receipts from public.admin_intake_receipts;
  for test_patch in select value from jsonb_array_elements('[{"price":10000},{"original_price":null},{"discount_value":100},{"discount_value":-1},{"discount_value":null},{"discount_type":"invalid"},{"discount_type":"amount","discount_value":20001}]'::jsonb) loop
    rejected:=false;
    begin
      changed:=jsonb_build_array(
        jsonb_build_object('kind','single','request_key',gen_random_uuid(),'item',item||jsonb_build_object('serial_number',2146100101)),
        jsonb_build_object('kind','single','request_key',gen_random_uuid(),'item',item||jsonb_build_object('serial_number',2146100102)||test_patch));
      perform public.admin_register_intake_collection(sid,gen_random_uuid(),changed);
    exception when others then rejected:=true;
    end;
    if not rejected then raise exception 'Invalid discount accepted: %',test_patch; end if;
    if (select count(*) from public.books)<>before_books or (select count(*) from public.admin_intake_receipts)<>before_receipts then
      raise exception 'Partial collection write survived invalid discount';
    end if;
  end loop;
end;
$test$;
select 'PASS: 정액·정률·반올림·옵션 예외·정가 미상·0%·구형 요청·중복 방지·잘못된 할인 전체 롤백' as verification;
rollback;
