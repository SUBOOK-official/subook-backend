-- 대표 사진을 공유하는 동일 교재 옵션별 일괄 등록. 전체 요청은 한 트랜잭션이다.
-- 기존 권별 RPC의 검수·채번·상품 연결·RLS 방어를 재사용하고 기존 함수를 변경하지 않는다.
begin;

create function public.admin_register_intake_batch(
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
revoke all on function public.admin_register_intake_batch(bigint,uuid,jsonb,jsonb) from public,anon;
grant execute on function public.admin_register_intake_batch(bigint,uuid,jsonb,jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
