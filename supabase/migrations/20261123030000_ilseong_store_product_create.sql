-- 「일성월심 앱」 화면에서 사이트에 팔 상품을 한 번에 만든다 (2026-11-23)
--
-- 배경: 앱 학습지를 수북에서 팔려면 지금은 화면 두 곳을 거친다.
--         ① 상품 등록에서 "수북 자체 매입" 묶음을 골라 상품과 재고를 만들고
--         ② 상품 재고 → 상품 상세에서 「앱 패키지로 지정」을 누른다.
--       ②를 빠뜨리면 앱 교재가 등록되지 않는 학습지가 사이트에 그대로 팔린다.
--       또 ②는 앱 상품 코드를 하나(ILSEONG_2028_SET4)로 고정해 보낸다. 앱 쪽에서 학습지와 상품을
--       여러 개 만들 수 있게 되면(앱 저장소 docs/adr/0039) 어느 앱 상품인지 골라야 한다.
--
-- 변경: admin_create_ilseong_store_product(p_payload) 추가. 한 거래 안에서
--         1) "수북 자체 매입" 묶음(shipments.is_direct_purchase)에 상품과 재고를 만든다
--            — 기존 admin_register_customer_inventory를 그대로 부른다(분류·가격·일련번호 규칙이 같다)
--         2) 그 상품을 앱 패키지로 지정한다 — 기존 admin_set_ilseong_app_product를 그대로 부른다
--            (자체 판매 지정, 앱 상품 코드 연결, 앱 패키지 판매가 꺼져 있으면 숨김)
--       을 한다. 어느 하나라도 실패하면 아무것도 남지 않는다.
--       p_payload: title, app_product_code, original_price, quantity(1–5000),
--                  subject?, brand?, book_type?, discount_type?(none|amount|rate), discount_value?,
--                  cover_image_url?, inspection_image_urls?, listed?(만들자마자 공개할지, 기본 false)
--       같은 이름·분류의 상품이 이미 있으면 재고를 더하지 않고 거절한다(만들기 전용).
--       전체 관리자(is_admin_user())만 부를 수 있다. 등록 담당 계정은 부를 수 없다.
--       기존 함수·표·권한·데이터는 바꾸지 않는다.
--
-- 롤백: drop function public.admin_create_ilseong_store_product(jsonb);

begin;

create or replace function public.admin_create_ilseong_store_product(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := nullif(btrim(coalesce(p_payload->>'title', '')), '');
  v_code text := btrim(coalesce(p_payload->>'app_product_code', ''));
  v_original integer;
  v_quantity integer;
  v_listed boolean := coalesce((p_payload->>'listed')::boolean, false);
  v_shipment bigint;
  v_last bigint;
  v_product_id bigint;
  v_base jsonb;
  v_items jsonb := '[]'::jsonb;
  v_left integer;
  v_registered jsonb;
  v_is_listed boolean;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if v_title is null then
    raise exception '상품 이름을 넣어 주세요.';
  end if;
  if v_code !~ '^[A-Za-z0-9_.:-]{1,64}$' then
    raise exception '어느 앱 상품을 여는 상품인지 골라 주세요.';
  end if;
  if coalesce(p_payload->>'original_price', '') !~ '^\s*[0-9]{1,9}\s*$' or coalesce(p_payload->>'quantity', '') !~ '^\s*[0-9]{1,5}\s*$' then
    raise exception '정가와 수량은 숫자로 넣어 주세요.';
  end if;
  v_original := btrim(p_payload->>'original_price')::integer;
  v_quantity := btrim(p_payload->>'quantity')::integer;
  if v_original < 1 then
    raise exception '정가를 넣어 주세요.';
  end if;
  if v_quantity < 1 or v_quantity > 5000 then
    raise exception '수량은 1–5000 사이로 넣어 주세요.';
  end if;

  -- 수북이 직접 파는 재고는 "수북 자체 매입" 묶음에 둔다(판매자 없음 · 팔려도 정산을 만들지 않는다)
  select id into v_shipment from public.shipments where is_direct_purchase order by id limit 1;
  if v_shipment is null then
    raise exception '수북 자체 매입 묶음이 없어 상품을 만들 수 없습니다.';
  end if;

  select coalesce(max(id), 0) into v_last from public.products;

  v_base := jsonb_build_object(
    'title', v_title,
    'subject', p_payload->>'subject',
    'brand', p_payload->>'brand',
    'book_type', p_payload->>'book_type',
    'original_price', v_original,
    'discount_type', coalesce(nullif(p_payload->>'discount_type', ''), 'none'),
    'discount_value', p_payload->>'discount_value',
    'option', '',
    'cover_image_url', p_payload->>'cover_image_url',
    'inspection_image_urls', coalesce(p_payload->'inspection_image_urls', '[]'::jsonb),
    'is_public', v_listed
  );
  -- 등록 함수는 한 줄에 999권까지 만든다. 넘는 수량은 같은 상품을 여러 줄로 나눠 보낸다(둘째 줄부터는 같은 상품에 재고가 붙는다)
  v_left := v_quantity;
  while v_left > 0 loop
    v_items := v_items || jsonb_build_array(v_base || jsonb_build_object('quantity', least(v_left, 999)));
    v_left := v_left - least(v_left, 999);
  end loop;
  v_registered := public.admin_register_customer_inventory(v_shipment, jsonb_build_object('new_products', v_items));

  select id into v_product_id from public.products where id > v_last and title = v_title order by id limit 1;
  if v_product_id is null then
    -- 등록 함수가 새 상품을 만들지 않고 있던 상품에 재고를 붙였다. 예외로 그 재고까지 되돌린다
    raise exception '같은 이름의 상품이 이미 있어요. 이름을 바꾸거나, 상품 재고에서 그 상품에 재고를 더해 주세요.';
  end if;

  perform public.admin_set_ilseong_app_product(v_product_id, true, v_code);

  select is_listed into v_is_listed from public.products where id = v_product_id;
  return jsonb_build_object(
    'product_id', v_product_id,
    'title', v_title,
    'app_product_code', v_code,
    'created_books', coalesce((v_registered->>'created_books')::integer, 0),
    'is_listed', coalesce(v_is_listed, false)
  );
end;
$$;

revoke all on function public.admin_create_ilseong_store_product(jsonb) from public, anon;
grant execute on function public.admin_create_ilseong_store_product(jsonb) to authenticated, service_role;

comment on function public.admin_create_ilseong_store_product(jsonb) is
  '일성월심 앱 화면: 수북 자체 매입 묶음에 상품·재고를 만들고 앱 패키지로 지정한다(한 거래).';

commit;
