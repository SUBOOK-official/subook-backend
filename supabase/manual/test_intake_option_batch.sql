-- 수동 회귀 검증: 옵션 일괄 등록 migration 적용 후 실행. shipment 1건 이상 필요.
-- 최종 ROLLBACK으로 테스트 재고·상품·영수증을 남기지 않는다.
begin;

select set_config('request.jwt.claim.role','service_role',true);
do $test$
declare sid bigint; item jsonb; variants jsonb; result jsonb; again jsonb; key uuid:=gen_random_uuid(); before_count int; receipt_count int;
begin
  select id into sid from public.shipments order by id limit 1;
  item:=jsonb_build_object('title','2027 옵션 일괄 등록 검증용','subject','수학','brand','기타','book_type','모의고사',
    'published_year',2027,'condition_grade','S','writing_percentage',0,'has_damage',false,'components_confirmed',true,
    'price',12000,'original_price',null,'location','TEST','serial_number',2147000001,'is_public',false,
    'cover_image_url','https://example.invalid/intake-cover.jpg','inspection_image_urls',jsonb_build_array('https://example.invalid/intake-detail.jpg'));
  select jsonb_agg(jsonb_build_object('option',i||'회','quantity',case when i=3 then 2 else 1 end,
    'price',case when i=3 then 8000 end,'condition_grade',case when i=3 then 'A_PLUS' end,
    'writing_percentage',case when i=3 then 2 end,'has_damage',case when i=3 then true end)) into variants from generate_series(1,30)i;
  select count(*) into before_count from public.books;
  result:=public.admin_register_intake_batch(sid,key,item,variants);
  again:=public.admin_register_intake_batch(sid,key,item,variants);
  if result->'books'<>again->'books' or (again->>'replayed')::boolean is not true or (select count(*) from public.books)<>before_count+31 then raise exception 'Batch replay/count failed'; end if;
  if (result->>'option_count')::int<>30 or (result->>'book_count')::int<>31 then raise exception 'Batch result failed'; end if;
  if (select count(distinct product_id) from public.books where serial_number between 2147000001 and 2147000031)<>1
    or (select count(distinct option) from public.books where serial_number between 2147000001 and 2147000031)<>30 then raise exception 'Product grouping failed'; end if;
  if (select count(*) from public.books where serial_number between 2147000001 and 2147000031 and cover_image_url=item->>'cover_image_url'
    and inspection_image_urls=ARRAY['https://example.invalid/intake-detail.jpg'] and original_price is null)<>31 then raise exception 'Shared images/original price failed'; end if;
  if (select count(*) from public.books where serial_number between 2147000001 and 2147000031 and option='3회'
    and condition_grade='A_PLUS' and writing_percentage=2 and has_damage and price=8000)<>2 then raise exception 'Variant overrides failed'; end if;
  if (select count(*) from public.books where serial_number between 2147000001 and 2147000031 and option<>'3회' and price=12000 and condition_grade='S')<>29 then raise exception 'Common defaults failed'; end if;
  begin
    perform public.admin_register_intake_batch(sid,key,item||jsonb_build_object('price',13000),variants);
    raise exception 'Changed payload accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  select count(*) into before_count from public.books;
  select count(*) into receipt_count from public.admin_intake_receipts;
  -- 첫 번째 권 저장 후 두 번째 권의 일련번호가 기존 재고와 충돌: 첫 번째 권도 없어야 한다.
  begin
    perform public.admin_register_intake_batch(sid,gen_random_uuid(),item||jsonb_build_object('serial_number',2147000000),
      jsonb_build_array(jsonb_build_object('option','첫 옵션','quantity',1),jsonb_build_object('option','충돌 옵션','quantity',1)));
    raise exception 'Serial collision accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  if (select count(*) from public.books)<>before_count or (select count(*) from public.admin_intake_receipts)<>receipt_count then raise exception 'Partial registration persisted'; end if;
  -- 뒤 옵션에 가격 오류가 있어도 앞의 등록과 영수증까지 롤백된다.
  begin
    perform public.admin_register_intake_batch(sid,gen_random_uuid(),item||jsonb_build_object('serial_number',2147000100),
      jsonb_build_array(jsonb_build_object('option','정상','quantity',1),jsonb_build_object('option','가격 오류','quantity',1,'price',-1)));
    raise exception 'Invalid price accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  if (select count(*) from public.books)<>before_count or (select count(*) from public.admin_intake_receipts)<>receipt_count then raise exception 'Partial rollback failed'; end if;
  begin
    perform public.admin_register_intake_batch(sid,gen_random_uuid(),item,
      jsonb_build_array(jsonb_build_object('option','1회','quantity',1),jsonb_build_object('option','１회','quantity',1)));
    raise exception 'Duplicate options accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  begin
    perform public.admin_register_intake_batch(sid,gen_random_uuid(),item,
      jsonb_build_array(jsonb_build_object('option','1회','quantity',0)));
    raise exception 'Invalid quantity accepted' using errcode='XX999';
  exception when raise_exception then null; end;
  perform set_config('request.jwt.claim.role','anon',true);
  begin
    perform public.admin_register_intake_batch(sid,gen_random_uuid(),item,variants);
    raise exception 'Anonymous allowed' using errcode='XX999';
  exception when raise_exception then null; end;
end;
$test$;
select 'PASS: 30 options/31 books, shared photos, defaults/overrides, serial mapping, replay, changed payload, atomic rollback, duplicates, quantity, authorization (rolled back)' as verification;

rollback;
