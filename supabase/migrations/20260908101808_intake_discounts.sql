-- 입력한 정액/정률 방식과 할인값을 재고에 보존한다. 스키마·RLS·기존 데이터 변경 없음.
begin;
create or replace function public.admin_register_intake_book(p_shipment_id bigint,p_request_key uuid,p_item jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_receipt public.admin_intake_receipts%rowtype;
  v_product public.products%rowtype;
  v_id bigint; v_serial integer; v_result jsonb; v_group text;
  v_grade text := p_item->>'condition_grade';
  v_price integer := nullif(p_item->>'price','')::integer;
  v_original integer := nullif(p_item->>'original_price','')::integer;
  v_discount_type text := nullif(p_item->>'discount_type','');
  v_discount_value integer := nullif(p_item->>'discount_value','')::integer;
  v_computed integer;
  v_year integer := nullif(p_item->>'published_year','')::integer;
  v_writing integer := nullif(p_item->>'writing_percentage','')::integer;
  v_damage boolean := (p_item->>'has_damage')::boolean;
  v_public boolean := coalesce((p_item->>'is_public')::boolean,true);
  v_title text := nullif(btrim(p_item->>'title'),'');
  v_subject_detail text := nullif(btrim(p_item->>'subject_detail'),'');
  v_details text[]; v_cover text := nullif(p_item->>'cover_image_url','');
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if p_request_key is null or jsonb_typeof(p_item) is distinct from 'object' then
    raise exception '등록 요청 정보가 없습니다.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_key::text,0));
  select * into v_receipt from public.admin_intake_receipts where request_key=p_request_key;
  if found then
    if v_receipt.shipment_id is distinct from p_shipment_id or v_receipt.payload is distinct from p_item then
      raise exception '이미 처리된 요청의 내용이 다릅니다. 등록 결과를 확인하세요.';
    end if;
    return v_receipt.result || jsonb_build_object('replayed',true);
  end if;
  if not exists(select 1 from public.shipments where id=p_shipment_id) then
    raise exception '수거 건을 다시 선택하세요.';
  end if;
  if v_title is null or v_grade is null or v_grade not in ('S','A_PLUS','A','DISCARD') then
    raise exception '교재명과 등급을 확인하세요.';
  end if;
  if v_grade='DISCARD' then
    if nullif(btrim(p_item->>'discard_reason'),'') is null then raise exception '판매불가 사유를 입력하세요.'; end if;
    v_public:=false; v_price:=null;
  else
    if v_price is null or v_price<=0 then raise exception '판매가는 1원 이상의 정수로 입력하세요.'; end if;
    if v_writing is null or v_writing<0 or v_writing>100 or v_damage is null
      or coalesce((p_item->>'components_confirmed')::boolean,false) is not true then
      raise exception '필기·손상·구성품 확인을 완료하세요.';
    end if;
    if nullif(btrim(p_item->>'location'),'') is null then raise exception '보관 위치를 입력하세요.'; end if;
  end if;
  if v_original is not null and v_original<=0 then raise exception '정가를 확인하거나 미상으로 비워두세요.'; end if;
  if v_grade='DISCARD' then
    v_discount_type:='none'; v_discount_value:=null;
  elsif p_item ? 'discount_type' then
    if v_discount_type is null or v_discount_type not in ('none','amount','rate') then raise exception '할인 방식을 확인하세요.'; end if;
    if v_discount_type in ('amount','rate') then
      if v_original is null or v_original<=0 or v_discount_value is null or v_discount_value<0 then raise exception '정가와 할인값을 확인하세요.'; end if;
      if v_discount_type='rate' and v_discount_value>=100 then raise exception '정률 할인은 0~99%%로 입력하세요.'; end if;
      if v_discount_type='amount' and v_discount_value>=v_original then raise exception '정액 할인은 정가보다 작게 입력하세요.'; end if;
      v_computed:=case when v_discount_type='rate' then round(v_original::numeric*(100-v_discount_value)/100)::integer else v_original-v_discount_value end;
      if v_computed<1 or v_price is distinct from v_computed then raise exception '할인 후 판매가가 계산과 다릅니다. 가격을 다시 확인하세요.'; end if;
    else v_discount_value:=null;
    end if;
  else
    -- 배포 전 요청은 기존 정액 역산 규칙을 유지한다.
    v_discount_type:=case when v_original>v_price then 'amount' else 'none' end;
    v_discount_value:=case when v_original>v_price then v_original-v_price end;
  end if;
  v_details:=array(select jsonb_array_elements_text(coalesce(p_item->'inspection_image_urls','[]'::jsonb)));
  if cardinality(v_details)>2 then raise exception '상세 사진은 최대 2장입니다.'; end if;
  if nullif(p_item->>'product_id','') is not null then
    select * into v_product from public.products where id=(p_item->>'product_id')::bigint;
    if not found then raise exception '선택한 교재가 없습니다. 다시 검색하세요.'; end if;
    v_title:=v_product.title;
    v_cover:=coalesce(v_product.cover_image_url,v_cover);
  elsif v_grade<>'DISCARD' then
    if v_year is null or v_year<2000 or v_year>2100
      or nullif(btrim(p_item->>'subject'),'') is null or nullif(btrim(p_item->>'brand'),'') is null
      or nullif(btrim(p_item->>'book_type'),'') is null then
      raise exception '신규 교재의 학년도·과목·브랜드·유형을 확인하세요.';
    end if;
    if v_subject_detail is not null and (
      p_item->>'subject' not in ('국어','수학','사회','과학') or char_length(v_subject_detail)>80
    ) then raise exception '하위 과목과 상위 과목을 확인하세요.'; end if;
    v_group:=public.storefront_product_group_key(v_title,null,p_item->>'subject',p_item->>'brand',
      p_item->>'book_type',v_year,nullif(btrim(p_item->>'instructor_name'),''));
    insert into public.products(group_key,title,subject,subject_detail,brand,book_type,published_year,instructor_name,cover_image_url,status)
    values(v_group,v_title,p_item->>'subject',v_subject_detail,p_item->>'brand',p_item->>'book_type',v_year,
      nullif(btrim(p_item->>'instructor_name'),''),v_cover,'hidden')
    on conflict(group_key) do nothing;
    select * into v_product from public.products where group_key=v_group;
    -- 옛 요청에는 subject_detail 키가 없다. 해당 경로는 기존 마스터를 그대로 이어 쓴다.
    if p_item ? 'subject_detail' and v_product.subject_detail is distinct from v_subject_detail then
      raise exception '같은 교재명이 다른 하위 과목으로 등록되어 있습니다. 기존 교재나 제목을 확인하세요.';
    end if;
    v_cover:=coalesce(v_product.cover_image_url,v_cover);
  end if;
  if v_public and v_cover is null then raise exception '공개 등록할 표지를 준비하세요.'; end if;
  v_serial:=nullif(p_item->>'serial_number','')::integer;
  if v_serial is null then v_serial:=public._next_book_serial(); end if;
  if v_serial<1 or exists(select 1 from public.books where serial_number=v_serial) then
    raise exception '일련번호 %는 사용할 수 없습니다. 다른 번호를 입력하세요.',v_serial;
  end if;
  insert into public.books(shipment_id,product_id,title,option,subject,subject_detail,brand,book_type,published_year,
    instructor_name,original_price,price,condition_grade,writing_percentage,has_damage,inspection_notes,
    inspected_at,cover_image_url,inspection_image_urls,is_public,status,serial_number,location,discard_reason,
    discount_type,discount_value)
  values(p_shipment_id,v_product.id,v_title,nullif(btrim(p_item->>'option'),''),v_product.subject,v_product.subject_detail,v_product.brand,
    v_product.book_type,v_product.published_year,v_product.instructor_name,v_original,v_price,v_grade,
    v_writing,v_damage,nullif(btrim(p_item->>'inspection_notes'),''),now(),v_cover,v_details,v_public,
    case when v_grade='DISCARD' then 'discarded' else 'on_sale' end,v_serial,
    nullif(normalize(btrim(p_item->>'location'),nfkc),''),
    case when v_grade='DISCARD' then btrim(p_item->>'discard_reason') end,
    v_discount_type,v_discount_value)
  returning id into v_id;
  v_result:=jsonb_build_object('success',true,'book_id',v_id,'product_id',v_product.id,
    'serial_number',v_serial,'title',v_title,'price',v_price,'is_public',v_public,'discarded',v_grade='DISCARD');
  insert into public.admin_intake_receipts(request_key,shipment_id,payload,result)
    values(p_request_key,p_shipment_id,p_item,v_result);
  return v_result;
end;
$$;

create or replace function public.admin_register_intake_batch(
  p_shipment_id bigint, p_request_key uuid, p_common jsonb, p_variants jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_receipt public.admin_intake_receipts%rowtype;
  v_payload jsonb := jsonb_build_object('kind','option_batch','common',p_common,'variants',p_variants);
  v_row jsonb; v_item jsonb; v_book jsonb; v_books jsonb := '[]'::jsonb; v_result jsonb;
  v_total integer := 0; v_quantity integer; v_index integer := 0; v_copy integer;
  v_start bigint; v_product bigint; v_option text; v_seen text[] := '{}'; v_key text; v_grade text;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if p_request_key is null or jsonb_typeof(p_common) is distinct from 'object'
    or jsonb_typeof(p_variants) is distinct from 'array' then raise exception '등록 요청 정보를 확인하세요.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_key::text,0));
  select * into v_receipt from public.admin_intake_receipts where request_key=p_request_key;
  if found then
    if v_receipt.shipment_id is distinct from p_shipment_id or v_receipt.payload is distinct from v_payload then
      raise exception '이미 처리된 요청의 내용이 다릅니다. 등록 결과를 확인하세요.';
    end if;
    return v_receipt.result || jsonb_build_object('replayed',true);
  end if;
  if jsonb_array_length(p_variants) not between 1 and 100 then raise exception '옵션은 1~100개로 등록하세요.'; end if;
  for v_row in select value from jsonb_array_elements(p_variants) loop
    if jsonb_typeof(v_row) is distinct from 'object' then raise exception '옵션 정보를 확인하세요.'; end if;
    v_option:=nullif(btrim(v_row->>'option'),'');
    if v_option is null then raise exception '모든 옵션에 회차·구성을 입력하세요.'; end if;
    v_key:=lower(btrim(normalize(v_option,nfkc)));
    if v_key=any(v_seen) then raise exception '%: 같은 옵션은 수량을 늘려주세요.',v_option; end if;
    v_seen:=array_append(v_seen,v_key);
    if coalesce(v_row->>'quantity','') !~ '^[0-9]{1,3}$' then raise exception '%: 수량은 1~100권입니다.',v_option; end if;
    v_quantity:=(v_row->>'quantity')::integer;
    if v_quantity not between 1 and 100 then raise exception '%: 수량은 1~100권입니다.',v_option; end if;
    v_total:=v_total+v_quantity;
    v_grade:=coalesce(nullif(v_row->>'condition_grade',''),p_common->>'condition_grade');
    if v_grade is null or v_grade not in ('S','A_PLUS','A') then raise exception '%: 판매 가능한 등급을 확인하세요.',v_option; end if;
  end loop;
  if v_total>300 then raise exception '한 번에 총 300권까지 등록할 수 있습니다.'; end if;
  v_start:=nullif(p_common->>'serial_number','')::bigint;
  if v_start is not null and (v_start<1 or v_start+v_total-1>2147483647) then raise exception '시작·마지막 일련번호 범위를 확인하세요.'; end if;
  v_product:=nullif(p_common->>'product_id','')::bigint;
  for v_row in select value from jsonb_array_elements(p_variants) loop
    v_option:=btrim(v_row->>'option');
    v_quantity:=(v_row->>'quantity')::integer;
    -- 회차마다 바꿀 수 있는 값만 허용. 상품·사진·보관 위치·공개 여부는 공통 값이다.
    v_item:=p_common || jsonb_build_object('option',v_option,
      'price',coalesce(nullif(v_row->>'price',''),p_common->>'price'),
      'condition_grade',coalesce(nullif(v_row->>'condition_grade',''),p_common->>'condition_grade'),
      'writing_percentage',coalesce(nullif(v_row->>'writing_percentage',''),p_common->>'writing_percentage'),
      'has_damage',coalesce(nullif(v_row->>'has_damage',''),p_common->>'has_damage')::boolean,
      'inspection_notes',coalesce(nullif(v_row->>'inspection_notes',''),p_common->>'inspection_notes'));
    -- 개별 판매가 예외는 할인 방식도 전달한다. 옛 본문에는 키를 추가하지 않는다.
    if v_row ? 'discount_type' then
      v_item:=v_item || jsonb_build_object('discount_type',v_row->'discount_type','discount_value',v_row->'discount_value');
    end if;
    for v_copy in 1..v_quantity loop
      begin
        v_book:=public.admin_register_intake_book(p_shipment_id,gen_random_uuid(),
          v_item || jsonb_build_object('product_id',v_product,'serial_number',case when v_start is not null then v_start+v_index end));
      exception when others then
        raise exception '%: %',v_option,sqlerrm;
      end;
      v_product:=(v_book->>'product_id')::bigint;
      v_books:=v_books || jsonb_build_array(v_book || jsonb_build_object('option',v_option));
      v_index:=v_index+1;
    end loop;
  end loop;
  v_result:=jsonb_build_object('success',true,'batch',true,'product_id',v_product,
    'title',v_books->0->>'title','is_public',(v_books->0->>'is_public')::boolean,
    'option_count',jsonb_array_length(p_variants),'book_count',v_total,'books',v_books);
  insert into public.admin_intake_receipts(request_key,shipment_id,payload,result)
    values(p_request_key,p_shipment_id,v_payload,v_result);
  return v_result;
end;
$$;

revoke all on function public.admin_register_intake_book(bigint,uuid,jsonb) from public,anon;
revoke all on function public.admin_register_intake_batch(bigint,uuid,jsonb,jsonb) from public,anon;
grant execute on function public.admin_register_intake_book(bigint,uuid,jsonb) to authenticated,service_role;
grant execute on function public.admin_register_intake_batch(bigint,uuid,jsonb,jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
