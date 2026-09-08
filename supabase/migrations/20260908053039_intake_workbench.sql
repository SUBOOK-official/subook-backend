-- 캠 작업대: 권별 원자적 등록·재시도 멱등성, 최근 입고, 내부 가격 비교.
-- 기존 일괄 등록 RPC·정산·수거 연결 트리거는 변경하지 않는다.
begin;

create table public.admin_intake_receipts (
  request_key uuid primary key,
  shipment_id bigint not null references public.shipments(id),
  created_by uuid default auth.uid(),
  payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.admin_intake_receipts enable row level security;
create policy admin_intake_receipts_read on public.admin_intake_receipts
  for select to authenticated using (public.is_admin_user());
revoke all on public.admin_intake_receipts from anon, authenticated;
grant select on public.admin_intake_receipts to authenticated;

create function public.admin_recent_intake_targets(p_limit integer default 30, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.target_date desc nulls last, t.sort_ts desc), '[]'::jsonb)
  into v_result from (
    select 'pickup_request'::text kind, pr.id ref_id, pr.request_number,
      pr.pickup_recipient_name seller_name, pr.pickup_recipient_phone seller_phone,
      pr.desired_pickup_date target_date, pr.status,
      (select count(*) from public.books b join public.shipments s on s.id=b.shipment_id
        where s.pickup_request_id=pr.id)::integer book_count,
      pr.expected_book_count, pr.box_count, pr.user_id, pr.created_at sort_ts
    from public.pickup_requests pr
    where pr.merged_into_id is null and pr.status in ('arrived','inspecting')
    union all
    select 'shipment', s.id, null, s.seller_name, s.seller_phone, s.pickup_date, s.status,
      (select count(*) from public.books b where b.shipment_id=s.id)::integer,
      null::integer, s.box_count, s.user_id, s.created_at
    from public.shipments s
    where s.pickup_request_id is null and not s.is_direct_purchase
      and s.status in ('scheduled','inspecting') and s.pickup_date <= current_date
    order by target_date desc nulls last, sort_ts desc
    limit greatest(1, least(coalesce(p_limit,30),50)) offset greatest(coalesce(p_offset,0),0)
  ) t;
  return v_result;
end;
$$;

create function public.admin_intake_price_context(p_item jsonb)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_product bigint := nullif(p_item->>'product_id','')::bigint;
  v_option text := coalesce(p_item->>'option','');
  v_grade text := p_item->>'condition_grade';
  v_sales jsonb; v_listings jsonb; v_recommended integer;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  -- 주문 당시의 상품 가격을 사용하고 현재 books.price와 섞지 않는다.
  with sales as (
    select 'order'::text source, oi.id, oi.title, oi.option_label option,
      oi.condition_grade, oi.unit_price price, coalesce(o.paid_at,o.created_at) sold_at
    from public.order_items oi join public.orders o on o.id=oi.order_id
    where oi.product_id=v_product and oi.refunded_at is null and oi.unit_price>0
      and o.payment_status='paid' and o.status in ('paid','preparing','shipping','delivered','confirmed')
    union all
    select 'legacy', ms.id, b.title, b.option, b.condition_grade, ms.sale_amount,
      coalesce(ms.sold_at::timestamptz,ms.created_at)
    from public.manual_settlements ms join public.books b on b.id=ms.book_id
    where b.product_id=v_product and b.status='settled' and ms.status<>'cancelled' and ms.sale_amount>0
      and not exists (select 1 from public.order_items oi join public.orders o on o.id=oi.order_id
        where oi.book_id=b.id and oi.refunded_at is null and o.payment_status='paid'
          and o.status in ('paid','preparing','shipping','delivered','confirmed'))
  ), recent as (
    select *, (coalesce(option,'')=v_option and condition_grade=v_grade) exact_match
    from sales order by sold_at desc, id desc limit 20
  )
  select coalesce(jsonb_agg(to_jsonb(recent) order by exact_match desc,sold_at desc),'[]'::jsonb),
    round(percentile_cont(0.5) within group(order by price) filter(where exact_match))::integer
  into v_sales,v_recommended from recent;

  with tokens as (
    select distinct lower(t) t from regexp_split_to_table(btrim(coalesce(p_item->>'title','')), '\s+') t
    where length(t)>=2 and t !~ '^20[0-9]{2}(학년도|년)?$'
  ), matches as (
    select p.*, (select count(*) from tokens where lower(p.title) like '%'||tokens.t||'%') hits
    from public.products p
    where p.id=v_product or (p.subject=nullif(p_item->>'subject','') and (
      exists(select 1 from tokens where lower(p.title) like '%'||tokens.t||'%')
      or (p.brand=nullif(p_item->>'brand','') and p.book_type=nullif(p_item->>'book_type',''))
    ))
  ), grouped as (
    select p.id product_id,p.title,p.published_year,p.brand,p.subject,p.book_type,p.cover_image_url,
      b.option,b.condition_grade,count(*)::integer stock_count,
      min(b.price) min_price,max(b.price) max_price,
      round(percentile_cont(0.5) within group(order by b.price))::integer price,
      (p.id=v_product) same_product,p.hits,
      (p.published_year=nullif(p_item->>'published_year','')::integer) same_year
    from matches p join public.books b on b.product_id=p.id
    where b.status='on_sale' and b.is_public and b.price>0
    group by p.id,p.title,p.published_year,p.brand,p.subject,p.book_type,p.cover_image_url,
      b.option,b.condition_grade,p.hits
    order by (p.id=v_product) desc nulls last,p.hits desc,
      (p.published_year=nullif(p_item->>'published_year','')::integer) desc nulls last,
      (b.condition_grade=v_grade) desc nulls last,(coalesce(b.option,'')=v_option) desc,p.id desc
    limit 8
  ) select coalesce(jsonb_agg(to_jsonb(grouped)),'[]'::jsonb) into v_listings from grouped;
  return jsonb_build_object('sales',v_sales,'listings',v_listings,'recommended_price',v_recommended);
end;
$$;

create function public.admin_register_intake_book(p_shipment_id bigint,p_request_key uuid,p_item jsonb)
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
  v_details text[]; v_cover text := nullif(p_item->>'cover_image_url','');
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if p_request_key is null or p_item is null then raise exception '등록 요청 정보가 없습니다.'; end if;
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
    v_group:=public.storefront_product_group_key(v_title,null,p_item->>'subject',p_item->>'brand',
      p_item->>'book_type',v_year,nullif(btrim(p_item->>'instructor_name'),''));
    insert into public.products(group_key,title,subject,brand,book_type,published_year,instructor_name,cover_image_url,status)
    values(v_group,v_title,p_item->>'subject',p_item->>'brand',p_item->>'book_type',v_year,
      nullif(btrim(p_item->>'instructor_name'),''),v_cover,'hidden')
    on conflict(group_key) do nothing;
    select * into v_product from public.products where group_key=v_group;
    v_cover:=coalesce(v_product.cover_image_url,v_cover);
  end if;
  if v_public and v_cover is null then raise exception '공개 등록할 표지를 준비하세요.'; end if;
  -- 기존 자동 채번 헬퍼·유니크 인덱스를 최종 방어선으로 사용한다.
  v_serial:=nullif(p_item->>'serial_number','')::integer;
  if v_serial is null then v_serial:=public._next_book_serial(); end if;
  if v_serial<1 or exists(select 1 from public.books where serial_number=v_serial) then
    raise exception '일련번호 %는 사용할 수 없습니다. 다른 번호를 입력하세요.',v_serial;
  end if;
  insert into public.books(shipment_id,product_id,title,option,subject,brand,book_type,published_year,
    instructor_name,original_price,price,condition_grade,writing_percentage,has_damage,inspection_notes,
    inspected_at,cover_image_url,inspection_image_urls,is_public,status,serial_number,location,discard_reason,
    discount_type,discount_value)
  values(p_shipment_id,v_product.id,v_title,nullif(btrim(p_item->>'option'),''),v_product.subject,v_product.brand,
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

revoke all on function public.admin_recent_intake_targets(integer,integer) from public,anon;
revoke all on function public.admin_intake_price_context(jsonb) from public,anon;
revoke all on function public.admin_register_intake_book(bigint,uuid,jsonb) from public,anon;
grant execute on function public.admin_recent_intake_targets(integer,integer) to authenticated,service_role;
grant execute on function public.admin_intake_price_context(jsonb) to authenticated,service_role;
grant execute on function public.admin_register_intake_book(bigint,uuid,jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
