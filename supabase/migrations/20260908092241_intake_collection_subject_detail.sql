-- 다량 촬영 후 여러 교재를 한 번에 등록한다. 어느 교재든 실패하면 전체가 롤백된다.
-- 과목은 기존 상위 분류를 유지하고, 선택한 하위 과목만 별도 저장한다.
-- 기존 데이터 백필·상품명 변경·RLS 완화 없이 기존 단권/옵션 요청의 재시도를 보존한다.
begin;

alter table public.products add column subject_detail text;
alter table public.books add column subject_detail text;

comment on column public.products.subject_detail is '선택한 하위 과목. NULL이면 상위 subject만 사용하며 종합 분류를 만들지 않는다.';
comment on column public.books.subject_detail is '입고 시 상품 마스터의 하위 과목을 보존한 값. 미선택은 NULL.';

alter table public.products add constraint products_subject_detail_check check (
  subject_detail is null or (
    subject in ('국어','수학','사회','과학')
    and char_length(subject_detail) between 1 and 80
    and subject_detail = btrim(subject_detail)
  )
);
alter table public.books add constraint books_subject_detail_check check (
  subject_detail is null or (
    subject is not null and subject in ('국어','수학','사회','과학')
    and char_length(subject_detail) between 1 and 80
    and subject_detail = btrim(subject_detail)
  )
);
-- products/books/admin_intake_receipts는 기존 RLS·권한 정책을 그대로 사용한다.

-- 하위 과목을 모르는 기존 수정 RPC/화면이 상위 과목만 바꿔도 이전 detail이 남아
-- 제약조건을 위반하지 않도록 한다. 새 상위/하위 값을 함께 지정하면 새 detail은 보존한다.
create function public.clear_unchanged_subject_detail_on_subject_change()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.subject is distinct from old.subject
    and new.subject_detail is not distinct from old.subject_detail then
    new.subject_detail:=null;
  end if;
  return new;
end;
$$;
create trigger books_clear_unchanged_subject_detail
  before update of subject on public.books
  for each row execute function public.clear_unchanged_subject_detail_on_subject_change();
create trigger products_clear_unchanged_subject_detail
  before update of subject on public.products
  for each row execute function public.clear_unchanged_subject_detail_on_subject_change();
revoke all on function public.clear_unchanged_subject_detail_on_subject_change() from public,anon,authenticated;

-- JSON 인자/영수증 payload는 그대로 유지하여 배포 전 pending 요청도 동일하게 재시도한다.
-- 기존 카탈로그 선택 시 사용자가 보낸 메타 대신 마스터 값을 복사하며 카탈로그를 수정하지 않는다.
create or replace function public.admin_register_intake_book(p_shipment_id bigint,p_request_key uuid,p_item jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_receipt public.admin_intake_receipts%rowtype;
  v_product public.products%rowtype;
  v_id bigint; v_serial integer; v_result jsonb; v_group text;
  v_grade text := p_item->>'condition_grade';
  v_price integer := nullif(p_item->>'price','')::integer;
  v_original integer := nullif(p_item->>'original_price','')::integer;
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
    case when v_original>v_price then 'amount' else 'none' end,
    case when v_original>v_price then v_original-v_price end)
  returning id into v_id;
  v_result:=jsonb_build_object('success',true,'book_id',v_id,'product_id',v_product.id,
    'serial_number',v_serial,'title',v_title,'price',v_price,'is_public',v_public,'discarded',v_grade='DISCARD');
  insert into public.admin_intake_receipts(request_key,shipment_id,payload,result)
    values(p_request_key,p_shipment_id,p_item,v_result);
  return v_result;
end;
$$;

create function public.admin_register_intake_collection(
  p_shipment_id bigint, p_request_key uuid, p_groups jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_receipt public.admin_intake_receipts%rowtype;
  v_payload jsonb := jsonb_build_object('kind','collection','groups',p_groups);
  v_group jsonb; v_variant jsonb; v_group_result jsonb; v_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_group_key uuid; v_keys uuid[] := '{}'; v_lock bigint;
  v_catalog_key text; v_catalog_locks bigint[] := '{}';
  v_total integer := 0; v_quantity integer; v_index integer := 0;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if p_request_key is null or p_shipment_id is null or jsonb_typeof(p_groups) is distinct from 'array' then
    raise exception '등록 요청 정보를 확인하세요.';
  end if;
  if jsonb_array_length(p_groups) not between 1 and 100 then
    raise exception '한 번에 교재 묶음 1~100개를 등록하세요.';
  end if;
  -- 등록 전에 요청 키와 총 수량을 검증한다. 그룹 순서가 달라도 잠금 순서는 같아야 한다.
  for v_group in select value from jsonb_array_elements(p_groups) loop
    if jsonb_typeof(v_group) is distinct from 'object'
      or jsonb_typeof(v_group->'item') is distinct from 'object'
      or coalesce(v_group->>'kind','') not in ('single','batch') then
      raise exception '교재 묶음의 등록 정보를 확인하세요.';
    end if;
    begin
      v_group_key:=nullif(v_group->>'request_key','')::uuid;
    exception when invalid_text_representation then
      raise exception '교재 묶음의 요청 키를 확인하세요.';
    end;
    if v_group_key is null or v_group_key=p_request_key or v_group_key=any(v_keys) then
      raise exception '교재 묶음마다 서로 다른 요청 키가 필요합니다.';
    end if;
    v_keys:=array_append(v_keys,v_group_key);
    -- 서로 다른 collection이 같은 상품들을 반대 순서로 INSERT/UPDATE하면서 교착되지
    -- 않도록 기존 상품과 신규 상품 모두 동일한 카탈로그 group_key로 잠금을 예약한다.
    v_catalog_key:=null;
    if nullif(v_group->'item'->>'product_id','') is not null then
      select p.group_key into v_catalog_key from public.products p
      where p.id=(v_group->'item'->>'product_id')::bigint;
    elsif v_group->>'kind'='batch' or coalesce(v_group->'item'->>'condition_grade','')<>'DISCARD' then
      v_catalog_key:=public.storefront_product_group_key(
        nullif(btrim(v_group->'item'->>'title'),''),null,v_group->'item'->>'subject',
        v_group->'item'->>'brand',v_group->'item'->>'book_type',
        nullif(v_group->'item'->>'published_year','')::integer,
        nullif(btrim(v_group->'item'->>'instructor_name'),'')
      );
    end if;
    if v_catalog_key is not null then
      v_catalog_locks:=array_append(v_catalog_locks,hashtextextended('intake-catalog:'||v_catalog_key,0));
    end if;
    if v_group->>'kind'='single' then
      v_total:=v_total+1;
    else
      if jsonb_typeof(v_group->'variants') is distinct from 'array' then
        raise exception '교재 묶음의 옵션 정보를 확인하세요.';
      end if;
      if jsonb_array_length(v_group->'variants') not between 1 and 100 then
        raise exception '옵션은 1~100개로 등록하세요.';
      end if;
      for v_variant in select value from jsonb_array_elements(v_group->'variants') loop
        if jsonb_typeof(v_variant) is distinct from 'object'
          or coalesce(v_variant->>'quantity','') !~ '^[0-9]{1,3}$' then
          raise exception '옵션별 수량은 1~100권입니다.';
        end if;
        v_quantity:=(v_variant->>'quantity')::integer;
        if v_quantity not between 1 and 100 then raise exception '옵션별 수량은 1~100권입니다.'; end if;
        v_total:=v_total+v_quantity;
        if v_total>300 then raise exception '한 번에 총 300권까지 등록할 수 있습니다.'; end if;
      end loop;
    end if;
    if v_total>300 then raise exception '한 번에 총 300권까지 등록할 수 있습니다.'; end if;
  end loop;
  for v_lock in
    select hashtextextended(k::text,0) from unnest(array_append(v_keys,p_request_key)) k
    union select unnest(v_catalog_locks)
    order by 1
  loop
    perform pg_advisory_xact_lock(v_lock);
  end loop;
  select * into v_receipt from public.admin_intake_receipts where request_key=p_request_key;
  if found then
    if v_receipt.shipment_id is distinct from p_shipment_id or v_receipt.payload is distinct from v_payload then
      raise exception '이미 처리된 요청의 내용이 다릅니다. 등록 결과를 확인하세요.';
    end if;
    return v_receipt.result || jsonb_build_object('replayed',true);
  end if;
  if not exists(select 1 from public.shipments where id=p_shipment_id) then
    raise exception '수거 건을 다시 선택하세요.';
  end if;
  for v_group in select value from jsonb_array_elements(p_groups) loop
    v_index:=v_index+1;
    v_group_key:=(v_group->>'request_key')::uuid;
    begin
      if v_group->>'kind'='single' then
        v_group_result:=public.admin_register_intake_book(p_shipment_id,v_group_key,v_group->'item');
      else
        v_group_result:=public.admin_register_intake_batch(p_shipment_id,v_group_key,v_group->'item',v_group->'variants');
      end if;
    exception when others then
      raise exception '%번째 교재: %',v_index,sqlerrm;
    end;
    v_results:=v_results || jsonb_build_array(v_group_result || jsonb_build_object('request_key',v_group_key));
  end loop;
  v_result:=jsonb_build_object('success',true,'collection',true,'group_count',jsonb_array_length(p_groups),
    'book_count',v_total,'groups',v_results);
  insert into public.admin_intake_receipts(request_key,shipment_id,payload,result)
    values(p_request_key,p_shipment_id,v_payload,v_result);
  return v_result;
end;
$$;

-- 기존 검색 RPC의 반환 시그니처는 유지하고 필요한 결과 ID의 하위 과목만 보충한다.
create function public.admin_intake_catalog_metadata(p_product_ids bigint[])
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if coalesce(cardinality(p_product_ids),0)>100 then raise exception '한 번에 교재 100개까지 조회하세요.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'subject_detail',p.subject_detail) order by p.id),'[]'::jsonb)
  into v_result from public.products p where p.id=any(p_product_ids);
  return v_result;
end;
$$;

revoke all on function public.admin_register_intake_book(bigint,uuid,jsonb) from public,anon;
revoke all on function public.admin_register_intake_collection(bigint,uuid,jsonb) from public,anon;
revoke all on function public.admin_intake_catalog_metadata(bigint[]) from public,anon;
grant execute on function public.admin_register_intake_book(bigint,uuid,jsonb) to authenticated,service_role;
grant execute on function public.admin_register_intake_collection(bigint,uuid,jsonb) to authenticated,service_role;
grant execute on function public.admin_intake_catalog_metadata(bigint[]) to authenticated,service_role;

-- 롤백 시 신규 collection UI를 먼저 이전 버전으로 되돌린다. 기존 RPC는 추가 컬럼을 무시하므로
-- 데이터 보존을 위해 컬럼/영수증을 삭제하지 않고 이전 단권 함수 정의를 복원할 수 있다.
notify pgrst,'reload schema';
commit;
