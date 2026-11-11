-- '등록 즉시 공개'는 관리자 공개 의사다. 기존 숨김 상품도 공개하되,
-- 이번에 추가하는 권만 공개한다. 일반 재입고/취소의 숨김 유지 트리거는 보존한다.
-- 기존 함수의 분류·채번·가격 로직 및 ACL/RLS를 유지하는 제한적 본문 교체.
-- 데이터 보정은 포함하지 않는다. 롤백은 이전 두 함수 정의 복원으로 가능하다.
begin;

do $migration$
declare
  definition text := pg_get_functiondef('public.admin_register_customer_inventory(bigint,jsonb)'::regprocedure);
  anchor text;
begin
  anchor := '  v_created_books integer := 0;';
  if strpos(definition, anchor) = 0 then raise exception 'register declaration drift'; end if;
  definition := replace(definition, anchor, anchor || E'\n  v_published_books integer := 0;');

  anchor := 'v_meta.year, v_meta.instructor, v_cover, ''selling''';
  if strpos(definition, anchor) = 0 then raise exception 'register new product drift'; end if;
  definition := replace(definition, anchor,
    'v_meta.year, v_meta.instructor, v_cover, case when v_is_public then ''selling'' else ''hidden'' end');

  -- 신규 입력이 기존 상품과 합쳐지는 경우도 포함. 기존 권의 비공개는 그대로 둔다.
  anchor := '    foreach v_optname in array v_options';
  if strpos(definition, anchor) = 0 then raise exception 'register new inventory drift'; end if;
  definition := replace(definition, anchor, $patch$
    if v_is_public then
      update public.products set is_listed = true, updated_at = now()
      where id = v_product_id and not is_listed;
    end if;

    foreach v_optname in array v_options$patch$);

  anchor := '      for v_i in 1..v_qty';
  if strpos(definition, anchor) = 0 then raise exception 'register existing inventory drift'; end if;
  definition := replace(definition, anchor, $patch$
      if v_is_public then
        update public.products set is_listed = true, updated_at = now()
        where id = v_product_id and not is_listed;
      end if;

      for v_i in 1..v_qty$patch$);

  anchor := '  return jsonb_build_object(';
  if strpos(definition, anchor) = 0 then raise exception 'register response drift'; end if;
  definition := replace(definition, anchor, $patch$
  select count(*)::integer into v_published_books
  from public.books b join public.products p on p.id = b.product_id
  where b.shipment_id = p_shipment_id and b.serial_number = any(v_created_serials)
    and b.status = 'on_sale' and b.is_public and p.is_listed;

  return jsonb_build_object($patch$);
  anchor := '''created_books'', v_created_books,';
  if strpos(definition, anchor) = 0 then raise exception 'register counts drift'; end if;
  definition := replace(definition, anchor, $patch$'created_books', v_created_books,
    'published_books', v_published_books,
    'unpublished_books', v_created_books - v_published_books,$patch$);
  execute definition;
end;
$migration$;

-- 공개 버튼도 books_enforce_public_storefront_rules의 실제 필수 조건과 일치시킨다.
-- 5/12에 해제된 과목/브랜드/연도/검수 세부값 요구가 이 RPC에만 남아 있었다.
do $migration$
declare
  definition text := pg_get_functiondef('public.admin_bulk_set_products_visibility(bigint[],boolean)'::regprocedure);
  anchor text := $old$      and nullif(btrim(coalesce(b.title, '')), '') is not null
      and nullif(btrim(coalesce(b.subject, '')), '') is not null
      and nullif(btrim(coalesce(b.brand, '')), '') is not null
      and nullif(btrim(coalesce(b.book_type, '')), '') is not null
      and b.published_year is not null
      and b.original_price is not null
      and b.price is not null
      and nullif(btrim(coalesce(b.cover_image_url, '')), '') is not null
      and nullif(btrim(coalesce(b.condition_grade, '')), '') is not null
      and b.writing_percentage is not null
      and b.has_damage is not null
      and b.inspected_at is not null;$old$;
begin
  if strpos(definition, anchor) = 0 then raise exception 'bulk visibility requirements drift'; end if;
  definition := replace(definition, anchor, $new$      and nullif(btrim(coalesce(b.title, '')), '') is not null
      and b.price is not null
      and nullif(btrim(coalesce(b.condition_grade, '')), '') is not null;$new$);
  execute definition;
end;
$migration$;

notify pgrst, 'reload schema';
commit;
