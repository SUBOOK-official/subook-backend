-- 상품 공개 의도(is_listed)와 가용 재고(status)를 분리한다.
-- 최신 운영 함수 정의(2026-09-23 KST) 기반. 옵션 무결성·재고 점검·전일 품절 예외 보존.
-- 이관: 공개 재고가 있거나, 마지막 숨김 전이가 판매/예약에 의한 것임이 입증된 상품만 공개.
-- 이력 불충분·빈 상품·숨긴 미판매 재고는 숨김 유지. books 데이터는 이관 중 변경하지 않는다.
-- products의 기존 RLS(공개 읽기, 관리자만 쓰기)를 그대로 적용하며 권한은 확대하지 않는다.
-- 롤백: frontend 이전 버전 + 본 migration 이전 함수/트리거 정의 복원 후
-- refresh_storefront_product_status로 재계산. is_listed 컬럼은 보존해 운영자 선택을 잃지 않는다.
-- 공식 문서: https://supabase.com/docs/reference/cli/supabase-db-push
begin;
lock table public.books, public.products in share row exclusive mode;

alter table public.products add column is_listed boolean not null default true;
comment on column public.products.is_listed is
  '상품 공개 설정. 재고 소진/주문 취소는 변경하지 않는다. false는 재입고 후에도 숨김 유지.';

-- 공개 재고가 없는 상품을 근거 없이 다시 공개하지 않는다.
update public.products p
set is_listed = (
  exists (select 1 from public.books b where b.product_id=p.id and b.status='on_sale' and b.is_public)
  or (
    not exists (select 1 from public.books b where b.product_id=p.id and b.status='on_sale')
    and exists (select 1 from public.books b where b.product_id=p.id and b.status in ('reserved','settled'))
    and exists (
      select 1 from (
        select l.* from public.product_status_logs l where l.product_id=p.id
        order by l.changed_at desc, l.id desc limit 1
      ) last_change
      where last_change.old_status='selling' and last_change.new_status='hidden'
        and exists (
          select 1 from public.books b join public.book_change_logs v on v.book_id=b.id
          where b.product_id=p.id and v.field='is_public' and v.old_value='true' and v.new_value='false'
            and v.changed_at=last_change.changed_at
            and exists (
              select 1 from public.book_change_logs s
              where s.book_id=b.id and s.changed_at=v.changed_at and s.field='status'
                and s.old_value='on_sale' and s.new_value in ('reserved','settled')
            )
        )
    )
  )
);

create or replace function public.products_enforce_derived_status()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  -- 기존 등록 RPC가 보내는 초기 hidden도 명시적 숨김으로 수용한다.
  if tg_op='INSERT' and new.status='hidden' then new.is_listed := false; end if;
  new.status := case
    when not new.is_listed then 'hidden'
    when exists(select 1 from public.books b where b.product_id=new.id and b.status='on_sale' and b.is_public)
      then 'selling'
    else 'sold_out'
  end;
  return new;
end;
$$;

create or replace trigger products_enforce_derived_status_trigger
before insert or update of status, is_listed on public.products
for each row execute function public.products_enforce_derived_status();

-- 직접 상품 UPDATE 및 재입고/취소의 경합에도 숨김 상품에 공개 재고가 남지 않게 한다.
-- false인 권은 다시 UPDATE하지 않으므로 books→products 트리거 재진입은 유한하다.
create or replace function public.products_apply_listing_visibility()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not new.is_listed then
    update public.books set is_public=false where product_id=new.id and is_public;
  end if;
  return new;
end;
$$;
revoke all on function public.products_apply_listing_visibility() from public, anon, authenticated;
create trigger products_apply_listing_visibility_trigger
after insert or update on public.products
for each row when (not new.is_listed)
execute function public.products_apply_listing_visibility();

create or replace function public.admin_set_book_visibility(p_book_id bigint, p_is_public boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product_id bigint; v_is_public boolean;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if p_is_public is null then raise exception '공개 여부를 지정해 주세요.'; end if;
  if p_is_public and exists (
    select 1 from public.books b join public.products p on p.id=b.product_id
    where b.id=p_book_id and not p.is_listed
  ) then raise exception '숨김 상품입니다. 상품을 먼저 공개한 뒤 재고를 공개해 주세요.'; end if;
  update public.books set is_public=p_is_public where id=p_book_id
    returning product_id,is_public into v_product_id,v_is_public;
  if v_product_id is null then raise exception '책을 찾을 수 없습니다.'; end if;
  perform public.refresh_storefront_product_status(v_product_id);
  return jsonb_build_object('success',true,'book_id',p_book_id,'is_public',v_is_public);
end;
$$;

-- 아래 함수들은 기존 운영 정의를 보존하고 공개 설정 관련 조건만 추가한다.

CREATE OR REPLACE FUNCTION public.books_enforce_public_storefront_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- 판매 중이 아니면 무조건 비노출 (product_id 연결은 유지: 위탁 히스토리)
  if new.status is distinct from 'on_sale' then
    new.is_public := false;
    return new;
  end if;

  -- 상품 숨김은 재입고와 주문 취소로 해제되지 않는다.
  if new.product_id is not null and exists (
    select 1 from public.products p where p.id=new.product_id and not p.is_listed
  ) then
    new.is_public := false;
  end if;

  -- is_public=true일 때 최소 조건만 검사
  if coalesce(new.is_public, false) then
    if new.product_id is null then
      raise exception 'Public books must be linked to a product master.';
    end if;

    if nullif(btrim(coalesce(new.title, '')), '') is null then
      raise exception 'Public books require a title.';
    end if;

    if new.price is null then
      raise exception 'Public books require a sale price.';
    end if;

    if nullif(btrim(coalesce(new.condition_grade, '')), '') is null then
      raise exception 'Public books require a condition grade.';
    end if;
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.refresh_storefront_product_status(p_product_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  next_title text;
  next_option text;
  next_subject text;
  next_brand text;
  next_book_type text;
  next_published_year integer;
  next_instructor_name text;
  next_cover_image_url text;
  next_public_on_sale_count integer;
  next_option_uniform boolean;
begin
  select
    b.title,
    b.option,
    b.subject,
    b.brand,
    b.book_type,
    b.published_year,
    b.instructor_name,
    b.cover_image_url
  into
    next_title,
    next_option,
    next_subject,
    next_brand,
    next_book_type,
    next_published_year,
    next_instructor_name,
    next_cover_image_url
  from public.books b
  where b.product_id = p_product_id
    and b.status = 'on_sale'
    and b.is_public = true
  order by
    public.storefront_condition_grade_rank(b.condition_grade),
    b.price asc nulls last,
    b.created_at desc,
    b.id desc
  limit 1;

  select
    count(*) filter (where b.status = 'on_sale' and b.is_public)::integer,
    (count(distinct coalesce(b.option, '')) filter (where b.status = 'on_sale' and b.is_public)) <= 1
  into
    next_public_on_sale_count,
    next_option_uniform
  from public.books b
  where b.product_id = p_product_id;

  update public.products p
  set
    title = coalesce(next_title, p.title),
    -- 권별 옵션이 서로 다른 상품(주간지 등)은 특정 권의 옵션을 상품 옵션으로 미러링하지
    -- 않는다 (2026-07-19: products.option 오염 → 수정 모달 프리필 → 전 권 덮어쓰기 사고 차단)
    option = case when next_option_uniform then coalesce(next_option, p.option) else p.option end,
    subject = coalesce(next_subject, p.subject),
    brand = coalesce(next_brand, p.brand),
    book_type = coalesce(next_book_type, p.book_type),
    published_year = coalesce(next_published_year, p.published_year),
    instructor_name = coalesce(next_instructor_name, p.instructor_name),
    cover_image_url = coalesce(next_cover_image_url, p.cover_image_url),
    status = case
      when not p.is_listed then 'hidden'
      when next_public_on_sale_count > 0 then 'selling'
      else 'sold_out'
    end,
    updated_at = now()
  where p.id = p_product_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_bulk_set_products_visibility(p_product_ids bigint[], p_is_public boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_updated integer := 0;
  v_products integer := 0;
  v_skipped bigint[] := '{}';
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_product_ids is null or coalesce(array_length(p_product_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'updated_books', 0, 'skipped_product_ids', '[]'::jsonb);
  end if;

  if p_is_public is null then raise exception '공개 여부를 지정해 주세요.'; end if;

  if p_is_public then
    update public.products set is_listed=true, updated_at=now()
      where id=any(p_product_ids) and not is_listed;
    get diagnostics v_products = row_count;
    -- books_enforce_public_storefront_rules(BEFORE 트리거)의 필수 필드 조건 미러 —
    -- 조건 미달 권에 is_public=true를 시도하면 예외로 전체 롤백되므로 사전 필터.
    update public.books b
    set is_public = true
    where b.product_id = any(p_product_ids)
      and b.is_public = false
      and b.status = 'on_sale'
      and nullif(btrim(coalesce(b.title, '')), '') is not null
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
      and b.inspected_at is not null;
    get diagnostics v_updated = row_count;

    -- 미판매 재고가 있지만 공개 조건이 안 맞는 상품만 안내한다. 품절 공개는 성공이다.
    select coalesce(array_agg(pid), '{}')
    into v_skipped
    from unnest(p_product_ids) as pid
    where exists (select 1 from public.books b where b.product_id=pid and b.status='on_sale')
      and not exists (
      select 1 from public.books b
      where b.product_id = pid and b.status = 'on_sale' and b.is_public = true
    );
  else
    update public.books b
    set is_public = false
    where b.product_id = any(p_product_ids)
      and b.is_public = true;
    get diagnostics v_updated = row_count;
    update public.products set is_listed=false, updated_at=now()
      where id=any(p_product_ids) and is_listed;
    get diagnostics v_products = row_count;
  end if;

  -- products.status·updated_at은 books 행 트리거(refresh_storefront_product_status)가 재계산.

  return jsonb_build_object(
    'success', true,
    'updated_products', coalesce(v_products, 0),
    'updated_books', coalesce(v_updated, 0),
    'skipped_product_ids', to_jsonb(coalesce(v_skipped, '{}'::bigint[]))
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_list_products_with_inventory(p_search text DEFAULT NULL::text, p_brand text DEFAULT NULL::text, p_subject text DEFAULT NULL::text, p_book_type text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_sort text DEFAULT 'updated'::text, p_issue text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_items jsonb;
  v_total integer;
  v_sort text;
  v_issue text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 알 수 없는 값은 기본(updated)으로 정규화
  v_sort := case when p_sort = 'created' then 'created' else 'updated' end;
  -- 알 수 없는 점검 항목은 필터 없음으로 취급
  v_issue := case
    when p_issue in ('any', 'missing_location', 'missing_serial', 'missing_detail_photo',
                     'missing_price', 'hidden_on_sale', 'missing_cover') then p_issue
    else null
  end;

  with iss as (
    select
      f.product_id,
      count(*) filter (where f.missing_location)::integer as missing_location,
      count(*) filter (where f.missing_location and f.picking_pending)::integer as missing_location_pending,
      count(*) filter (where f.missing_serial)::integer as missing_serial,
      count(*) filter (where f.missing_detail_photo)::integer as missing_detail_photo,
      count(*) filter (where f.missing_price)::integer as missing_price,
      count(*) filter (where f.hidden_on_sale)::integer as hidden_on_sale,
      count(*) filter (where f.is_on_sale)::integer as on_sale
    from public._admin_inventory_book_flags() f
    group by f.product_id
  )
  select count(*)::integer
  into v_total
  from public.products p
  left join iss on iss.product_id = p.id
  where (
    p_search is null or p_search = '' or
    p.title ilike '%' || p_search || '%' or
    coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
    coalesce(p.option, '') ilike '%' || p_search || '%' or
    (p_search ~ '^\d+$' and length(p_search) <= 9 and exists (
      select 1 from public.books bs
      where bs.product_id = p.id and bs.serial_number = p_search::integer
    ))
  )
  and (p_brand is null or p_brand = '' or p.brand = p_brand)
  and (p_subject is null or p_subject = '' or p.subject = p_subject)
  and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
  and (p_status is null or p_status = '' or p.status = p_status)
  and (
    v_issue is null
    or (v_issue = 'missing_location' and coalesce(iss.missing_location, 0) > 0)
    or (v_issue = 'missing_serial' and coalesce(iss.missing_serial, 0) > 0)
    or (v_issue = 'missing_detail_photo' and coalesce(iss.missing_detail_photo, 0) > 0)
    or (v_issue = 'missing_price' and coalesce(iss.missing_price, 0) > 0)
    or (v_issue = 'hidden_on_sale' and coalesce(iss.hidden_on_sale, 0) > 0)
    or (v_issue = 'missing_cover' and coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
    or (v_issue = 'any' and (
      coalesce(iss.missing_location, 0) + coalesce(iss.missing_serial, 0) + coalesce(iss.missing_detail_photo, 0)
        + coalesce(iss.missing_price, 0) + coalesce(iss.hidden_on_sale, 0) > 0
      or (coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
    ))
  );

  with iss as (
    select
      f.product_id,
      count(*) filter (where f.missing_location)::integer as missing_location,
      count(*) filter (where f.missing_location and f.picking_pending)::integer as missing_location_pending,
      count(*) filter (where f.missing_serial)::integer as missing_serial,
      count(*) filter (where f.missing_detail_photo)::integer as missing_detail_photo,
      count(*) filter (where f.missing_price)::integer as missing_price,
      count(*) filter (where f.hidden_on_sale)::integer as hidden_on_sale,
      count(*) filter (where f.is_on_sale)::integer as on_sale
    from public._admin_inventory_book_flags() f
    group by f.product_id
  )
  select coalesce(jsonb_agg(row_data
    order by
      (case when v_sort = 'created' then row_data->>'created_at' else row_data->>'updated_at' end) desc nulls last,
      (row_data->>'id')::bigint desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', p.id,
      'group_key', p.group_key,
      'title', p.title,
      'option', p.option,
      'subject', p.subject,
      'brand', p.brand,
      'book_type', p.book_type,
      'published_year', p.published_year,
      'instructor_name', p.instructor_name,
      'cover_image_url', p.cover_image_url,
      'status', p.status,
      'is_listed', p.is_listed,
      'created_at', p.created_at,
      'updated_at', p.updated_at,
      'inventory_count', coalesce(inv.on_sale_count, 0),
      'public_count', coalesce(inv.public_count, 0),
      'total_book_count', coalesce(inv.total_count, 0),
      'min_price', inv.min_price,
      'max_price', inv.max_price,
      'locations', coalesce(to_jsonb(inv.locations), '[]'::jsonb),
      -- 수북 자체 판매 교재 (2026-09-15) — 위치·일련번호·상세사진 점검 제외 대상
      'is_direct_sale', exists (select 1 from public.direct_sale_products ds where ds.product_id = p.id),
      'issues', jsonb_build_object(
        'missing_location', coalesce(iss.missing_location, 0),
        'missing_location_pending', coalesce(iss.missing_location_pending, 0),
        'missing_serial', coalesce(iss.missing_serial, 0),
        'missing_detail_photo', coalesce(iss.missing_detail_photo, 0),
        'missing_price', coalesce(iss.missing_price, 0),
        'hidden_on_sale', coalesce(iss.hidden_on_sale, 0),
        'missing_cover', coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null
      )
    ) as row_data
    from public.products p
    left join iss on iss.product_id = p.id
    left join lateral (
      select
        count(*) filter (where b.status = 'on_sale') as on_sale_count,
        count(*) filter (where b.status = 'on_sale' and b.is_public = true) as public_count,
        count(*) as total_count,
        min(b.price) filter (where b.status = 'on_sale') as min_price,
        max(b.price) filter (where b.status = 'on_sale') as max_price,
        array_agg(distinct b.location order by b.location)
          filter (where b.status = 'on_sale' and b.location is not null) as locations
      from public.books b
      where b.product_id = p.id
    ) inv on true
    where (
      p_search is null or p_search = '' or
      p.title ilike '%' || p_search || '%' or
      coalesce(p.instructor_name, '') ilike '%' || p_search || '%' or
      coalesce(p.option, '') ilike '%' || p_search || '%' or
      (p_search ~ '^\d+$' and length(p_search) <= 9 and exists (
        select 1 from public.books bs
        where bs.product_id = p.id and bs.serial_number = p_search::integer
      ))
    )
    and (p_brand is null or p_brand = '' or p.brand = p_brand)
    and (p_subject is null or p_subject = '' or p.subject = p_subject)
    and (p_book_type is null or p_book_type = '' or p.book_type = p_book_type)
    and (p_status is null or p_status = '' or p.status = p_status)
    and (
      v_issue is null
      or (v_issue = 'missing_location' and coalesce(iss.missing_location, 0) > 0)
      or (v_issue = 'missing_serial' and coalesce(iss.missing_serial, 0) > 0)
      or (v_issue = 'missing_detail_photo' and coalesce(iss.missing_detail_photo, 0) > 0)
      or (v_issue = 'missing_price' and coalesce(iss.missing_price, 0) > 0)
      or (v_issue = 'hidden_on_sale' and coalesce(iss.hidden_on_sale, 0) > 0)
      or (v_issue = 'missing_cover' and coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
      or (v_issue = 'any' and (
        coalesce(iss.missing_location, 0) + coalesce(iss.missing_serial, 0) + coalesce(iss.missing_detail_photo, 0)
          + coalesce(iss.missing_price, 0) + coalesce(iss.hidden_on_sale, 0) > 0
        or (coalesce(iss.on_sale, 0) > 0 and nullif(btrim(p.cover_image_url), '') is null)
      ))
    )
    order by
      (case when v_sort = 'created' then p.created_at else p.updated_at end) desc nulls last,
      p.id desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.list_public_store_products(p_subjects text[] DEFAULT NULL::text[], p_book_types text[] DEFAULT NULL::text[], p_brands text[] DEFAULT NULL::text[], p_years integer[] DEFAULT NULL::integer[], p_condition_grades text[] DEFAULT NULL::text[], p_search text DEFAULT NULL::text, p_sort text DEFAULT 'popular'::text, p_limit integer DEFAULT 24, p_offset integer DEFAULT 0, p_instructors text[] DEFAULT NULL::text[], p_title_terms text[] DEFAULT NULL::text[])
 RETURNS TABLE(id bigint, product_id bigint, title text, option text, subject text, brand text, book_type text, published_year integer, instructor_name text, condition_grade text, price integer, original_price integer, discount_rate integer, cover_image_url text, inspection_image_urls text[], writing_percentage integer, has_damage boolean, inspection_notes text, inspected_at timestamp with time zone, created_at timestamp with time zone, popularity_score integer, available_option_count integer, total_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with params as (
    select
      lower(coalesce(btrim(p_sort), 'popular')) as sort_key,
      btrim(coalesce(p_search, '')) as search_term,
      -- 4자리 학년도는 유사어가 아니라 기존 연도 필터와 같은 정확 일치 조건이다.
      substring(coalesce(p_search, '') from '(?<![0-9])20[0-9]{2}(?![0-9])')::integer as search_year,
      lower(btrim(coalesce(p_search, ''))) as search_lower,
      public.extract_chosung(lower(btrim(coalesce(p_search, '')))) as search_chosung,
      (btrim(coalesce(p_search, '')) <> '' and btrim(coalesce(p_search, '')) !~ '[가-힣]') as is_chosung_only,
      -- 오타 임계(글자수 적응형): 첫 글자만 겹친 점수(1/(글자수+1))보다 높아야 통과
      greatest(0.25, 1.0 / (char_length(lower(btrim(coalesce(p_search, 'x')))) + 1) + 0.05)::real as typo_threshold
  ),
  -- 주문마다 같은 상품은 한 번만 센다. 판매 수량은 동률 보조 지표다.
  recent_sales as (
    select
      oi.product_id,
      count(distinct o.id) as order_count_30d,
      count(distinct o.id) filter (
        where coalesce(o.paid_at, o.pg_approved_at) >= now() - interval '7 days'
      ) as order_count_7d,
      sum(oi.quantity) as sales_count_30d
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where o.payment_status = 'paid'
      and o.status not in ('cancelled', 'refunded')
      and oi.refunded_at is null
      and coalesce(o.paid_at, o.pg_approved_at) >= now() - interval '30 days'
      and coalesce(o.paid_at, o.pg_approved_at) <= now()
    group by oi.product_id
  ),
  favorites as (
    select w.product_id, count(*) as favorite_count
    from public.wishlist_items w
    group by w.product_id
  ),
  candidate_books as (
    select
      p.id as product_id,
      p.title,
      p.option,
      p.subject,
      p.brand,
      p.book_type,
      p.published_year,
      p.instructor_name,
      p.cover_image_url as product_cover_image_url,
      b.id as book_id,
      (b.status = 'on_sale' and b.is_public) as is_available,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url as book_cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at as book_created_at,
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank,
      -- 상품 매칭 점수: 부분(오타) 유사도 포함 — 정확 포함(0.8~1.0) > 오타(0.25~0.6) > 노이즈
      case
        when params.search_term = '' then 0::real
        else greatest(
          similarity(coalesce(p.search_text, ''), params.search_lower),
          word_similarity(params.search_lower, coalesce(p.search_text, '')),
          case when params.is_chosung_only
            then similarity(coalesce(p.search_chosung, ''), params.search_chosung)
            else 0
          end,
          case when position(params.search_lower in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
        )::real
      end as match_score
    from public.products p
    join public.books b
      on b.product_id = p.id
    cross join params
    where p.is_listed and ((b.status = 'on_sale' and b.is_public = true)
      or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        )))
      and (params.search_year is null or p.published_year = params.search_year)
      and (coalesce(cardinality(p_subjects), 0) = 0 or p.subject = any(p_subjects))
      and (coalesce(cardinality(p_book_types), 0) = 0 or p.book_type = any(p_book_types))
      and (coalesce(cardinality(p_brands), 0) = 0 or p.brand = any(p_brands))
      and (coalesce(cardinality(p_years), 0) = 0 or p.published_year = any(p_years))
      -- 강사 랜딩: instructor_name 정확 일치 (2026-08-19)
      and (coalesce(cardinality(p_instructors), 0) = 0 or p.instructor_name = any(p_instructors))
      -- 시리즈 랜딩: 상품명 부분 일치 — 한/영 표기 중 하나라도 매칭 (2026-08-19)
      and (
        coalesce(cardinality(p_title_terms), 0) = 0
        or exists (
          select 1
          from unnest(p_title_terms) as series_term
          where p.title ilike '%' || series_term || '%'
        )
      )
      and (
        coalesce(cardinality(p_condition_grades), 0) = 0
        or b.condition_grade = any(p_condition_grades)
      )
      and (
        params.search_term = ''
        -- FTS: search_text 부분일치
        or coalesce(p.search_text, '') ilike '%' || params.search_lower || '%'
        -- 초성 검색 (ㅅㄷㅇㅈ → 시대인재)
        or (params.is_chosung_only and coalesce(p.search_chosung, '') ilike '%' || params.search_chosung || '%')
        -- 오타 허용: 부분(word) 유사도, 글자수 적응 임계 (2026-07-23)
        or word_similarity(params.search_lower, coalesce(p.search_text, '')) >= params.typo_threshold
        -- 기존 ILIKE에서만 커버되던 book 단위 필드 보존 (회차 옵션·연도 검색 회귀 방지)
        or coalesce(b.option, '') ilike '%' || params.search_term || '%'
        or coalesce(b.published_year::text, '') ilike '%' || params.search_term || '%'
      )
  ),
  ranked_books as (
    select
      candidate_books.*,
      row_number() over (
        partition by candidate_books.product_id
        order by
          candidate_books.price asc nulls last,
          candidate_books.condition_rank asc,
          candidate_books.book_created_at desc,
          candidate_books.book_id desc
      ) as representative_rank,
      count(*) filter (where candidate_books.is_available) over (partition by candidate_books.product_id) as available_option_count,
      max(candidate_books.match_score) over (partition by candidate_books.product_id) as product_match_score,
      max(candidate_books.book_created_at) over (partition by candidate_books.product_id) as latest_book_created_at
    from candidate_books
  ),
  representative_products as (
    select
      ranked_books.*,
      coalesce(recent_sales.order_count_30d, 0) as order_count_30d,
      coalesce(recent_sales.order_count_7d, 0) as order_count_7d,
      coalesce(recent_sales.sales_count_30d, 0) as sales_count_30d,
      coalesce(favorites.favorite_count, 0) as favorite_count
    from ranked_books
    left join recent_sales on recent_sales.product_id = ranked_books.product_id
    left join favorites on favorites.product_id = ranked_books.product_id
    where ranked_books.representative_rank = 1
  ),
  scored_products as (
    select
      representative_products.*,
      -- 기존 RPC 반환형(int4)과 구버전 클라이언트 호환.
      -- 지표를 자릿수에 패킹하지 않고 정렬 순위를 점수로 바꾸므로 판매수 캡이 없다.
      -- 점수는 현재 필터 결과 안에서만 비교하는 순서값이며 판매량이 아니다.
      (2147483647 - row_number() over (
        order by
          order_count_30d desc,
          order_count_7d desc,
          sales_count_30d desc,
          -- 최근 구매가 없는 교재는 찜/과거 판매/할인 점수 대신 최근 입고순으로 탐색.
          case when order_count_30d > 0 then favorite_count else 0 end desc,
          latest_book_created_at desc,
          product_id desc
      ))::integer as product_popularity_score
    from representative_products
  ),
  ordered as (
    select
      scored_products.*
    from scored_products
    cross join params
    order by
      case when params.sort_key = 'relevance' then scored_products.product_match_score end desc nulls last,
      case when params.sort_key = 'latest' then scored_products.latest_book_created_at end desc nulls last,
      case when params.sort_key = 'price_low' then scored_products.price end asc nulls last,
      case when params.sort_key = 'price_high' then scored_products.price end desc nulls last,
      case when params.sort_key = 'popular' then scored_products.product_popularity_score end desc nulls last,
      -- relevance 동점(동일 match_score) 시 인기 → 최신 순으로 이어서 안정 정렬
      case when params.sort_key = 'relevance' then scored_products.product_popularity_score end desc nulls last,
      scored_products.latest_book_created_at desc,
      scored_products.product_id desc
  )
  select
    ordered.product_id as id,
    ordered.product_id,
    ordered.title,
    ordered.option,
    ordered.subject,
    ordered.brand,
    ordered.book_type,
    ordered.published_year,
    ordered.instructor_name,
    ordered.condition_grade,
    ordered.price,
    ordered.original_price,
    ordered.discount_rate,
    coalesce(ordered.book_cover_image_url, ordered.product_cover_image_url) as cover_image_url,
    ordered.inspection_image_urls,
    ordered.writing_percentage,
    ordered.has_damage,
    ordered.inspection_notes,
    ordered.inspected_at,
    ordered.latest_book_created_at as created_at,
    ordered.product_popularity_score as popularity_score,
    ordered.available_option_count,
    count(*) over()::integer as total_count
  from ordered
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 24), 500));
$function$
;

CREATE OR REPLACE FUNCTION public.get_public_store_product_detail(p_product_id bigint)
 RETURNS TABLE(id bigint, product_id bigint, title text, option text, subject text, brand text, book_type text, published_year integer, instructor_name text, condition_grade text, price integer, original_price integer, discount_rate integer, cover_image_url text, inspection_image_urls text[], writing_percentage integer, has_damage boolean, inspection_notes text, inspected_at timestamp with time zone, created_at timestamp with time zone, related_books jsonb, option_books jsonb, available_option_count integer, sold_out_option_count integer, total_option_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with target_product as (
    select p.*
    from public.products p
    where p.id = p_product_id and p.is_listed
      and exists (
        select 1
        from public.books b
        where b.product_id = p.id
          and ((b.status = 'on_sale' and b.is_public = true)
          or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        )))
      )
    limit 1
  ),
  representative_book as (
    select
      b.id as book_id,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url as book_cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at as book_created_at
    from public.books b
    join target_product p
      on p.id = b.product_id
    where ((b.status = 'on_sale' and b.is_public = true)
      or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        )))
    order by
      public.storefront_condition_grade_rank(b.condition_grade),
      b.price asc nulls last,
      b.created_at desc,
      b.id desc
    limit 1
  ),
  option_book_rows as (
    select
      b.id as book_id,
      b.product_id,
      b.title,
      b.option,
      b.subject,
      b.brand,
      b.book_type,
      b.published_year,
      b.instructor_name,
      b.condition_grade,
      b.price,
      b.original_price,
      case
        when b.original_price is null or b.original_price <= 0 or b.price is null then null
        else greatest(0, least(100, round(((b.original_price - b.price)::numeric / b.original_price) * 100)::integer))
      end as discount_rate,
      b.cover_image_url,
      b.inspection_image_urls,
      b.writing_percentage,
      b.has_damage,
      b.inspection_notes,
      b.inspected_at,
      b.created_at,
      (b.status = 'on_sale' and b.is_public) as is_available,
      case
        when b.status = 'on_sale' and b.is_public then 'selling'
        else 'sold_out'
      end as availability_status,
      case
        when b.status = 'on_sale' and b.is_public then 1
        else 0
      end as stock_count,
      case
        when b.status = 'on_sale' and b.is_public then 0
        else 1
      end as availability_rank,
      public.storefront_condition_grade_rank(b.condition_grade) as condition_rank
    from public.books b
    join target_product p
      on p.id = b.product_id
    where b.is_public = true or (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        ))
  ),
  option_books as (
    select
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'book_id', option_book_rows.book_id,
            'product_id', option_book_rows.product_id,
            'title', option_book_rows.title,
            'option', option_book_rows.option,
            'subject', option_book_rows.subject,
            'brand', option_book_rows.brand,
            'book_type', option_book_rows.book_type,
            'published_year', option_book_rows.published_year,
            'instructor_name', option_book_rows.instructor_name,
            'condition_grade', option_book_rows.condition_grade,
            'price', option_book_rows.price,
            'original_price', option_book_rows.original_price,
            'discount_rate', option_book_rows.discount_rate,
            'cover_image_url', option_book_rows.cover_image_url,
            'inspection_image_urls', option_book_rows.inspection_image_urls,
            'writing_percentage', option_book_rows.writing_percentage,
            'has_damage', option_book_rows.has_damage,
            'inspection_notes', option_book_rows.inspection_notes,
            'inspected_at', option_book_rows.inspected_at,
            'created_at', option_book_rows.created_at,
            'status', option_book_rows.availability_status,
            'is_available', option_book_rows.is_available,
            'stock_count', option_book_rows.stock_count
          )
          order by
            option_book_rows.availability_rank,
            option_book_rows.condition_rank,
            option_book_rows.price asc nulls last,
            option_book_rows.created_at desc,
            option_book_rows.book_id desc
        ),
        '[]'::jsonb
      ) as option_books,
      count(*) filter (where option_book_rows.is_available)::integer as available_option_count,
      count(*) filter (where not option_book_rows.is_available)::integer as sold_out_option_count,
      count(*)::integer as total_option_count
    from option_book_rows
  ),
  related_books as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', related_product.id,
          'product_id', related_product.product_id,
          'title', related_product.title,
          'option', related_product.option,
          'subject', related_product.subject,
          'brand', related_product.brand,
          'book_type', related_product.book_type,
          'published_year', related_product.published_year,
          'instructor_name', related_product.instructor_name,
          'condition_grade', related_product.condition_grade,
          'price', related_product.price,
          'original_price', related_product.original_price,
          'discount_rate', related_product.discount_rate,
          'cover_image_url', related_product.cover_image_url,
          'inspection_image_urls', related_product.inspection_image_urls,
          'writing_percentage', related_product.writing_percentage,
          'has_damage', related_product.has_damage,
          'inspection_notes', related_product.inspection_notes,
          'inspected_at', related_product.inspected_at,
          'created_at', related_product.created_at,
          'popularity_score', related_product.popularity_score,
          'available_option_count', related_product.available_option_count
        )
        order by related_product.popularity_score desc, related_product.created_at desc, related_product.id desc
      ),
      '[]'::jsonb
    ) as related_books
    from target_product tp
    cross join lateral (
      select *
      from public.list_public_store_products(
        array[tp.subject],
        array[tp.book_type],
        array[tp.brand],
        array[tp.published_year],
        null,
        null,
        'popular',
        6,
        0
      )
      where id <> tp.id
    ) related_product
  )
  select
    target_product.id,
    target_product.id,
    target_product.title,
    target_product.option,
    target_product.subject,
    target_product.brand,
    target_product.book_type,
    target_product.published_year,
    target_product.instructor_name,
    representative_book.condition_grade,
    representative_book.price,
    representative_book.original_price,
    representative_book.discount_rate,
    coalesce(representative_book.book_cover_image_url, target_product.cover_image_url) as cover_image_url,
    representative_book.inspection_image_urls,
    representative_book.writing_percentage,
    representative_book.has_damage,
    representative_book.inspection_notes,
    representative_book.inspected_at,
    representative_book.book_created_at as created_at,
    related_books.related_books,
    option_books.option_books,
    option_books.available_option_count,
    option_books.sold_out_option_count,
    option_books.total_option_count
  from target_product
  left join representative_book on true
  cross join related_books
  cross join option_books;
$function$
;

CREATE OR REPLACE FUNCTION public.search_storefront_products(p_query text, p_limit integer DEFAULT 30, p_offset integer DEFAULT 0)
 RETURNS TABLE(id bigint, title text, option text, subject text, brand text, book_type text, published_year integer, instructor_name text, cover_image_url text, status text, price integer, condition_grade text, available_count integer, match_score real)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_q_chosung text;
  v_search_year integer := substring(v_q from '(?<![0-9])20[0-9]{2}(?![0-9])')::integer;
  v_is_chosung_only boolean;
  v_typo_threshold real;
begin
  if v_q = '' then
    return;
  end if;

  v_q_chosung := public.extract_chosung(v_q);
  v_is_chosung_only := v_q !~ '[가-힣]';
  -- 오타 임계(글자수 적응형) — 그리드 RPC와 동일 공식 (2026-07-23)
  v_typo_threshold := greatest(0.25, 1.0 / (char_length(v_q) + 1) + 0.05)::real;

  return query
  with matched as (
    select
      p.id, p.title, p.option, p.subject, p.brand, p.book_type,
      p.published_year, p.instructor_name, p.cover_image_url,
      case when p.status = 'hidden' then 'sold_out' else p.status end as status,
      greatest(
        similarity(p.search_text, v_q),
        word_similarity(v_q, coalesce(p.search_text, '')),
        case when v_is_chosung_only then similarity(p.search_chosung, v_q_chosung) else 0 end,
        case when position(v_q in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
      )::real as match_score
    from public.products p
    where p.is_listed and (p.status = 'selling' or exists (
      select 1 from public.books b where b.product_id = p.id and (p.brand = '전일학원' and p.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = p.id and unsold.status = 'on_sale'
        ))
    ))
      -- 자동완성과 목록의 학년도 범위를 일치시킨다. 복합 검색에도 적용한다.
      and (v_search_year is null or p.published_year = v_search_year)
      and (
        p.search_text ilike '%' || v_q || '%'
        or (v_is_chosung_only and p.search_chosung ilike '%' || v_q_chosung || '%')
        -- 오타 허용: 부분 유사도, 글자수 적응 임계 (2026-07-23)
        or word_similarity(v_q, coalesce(p.search_text, '')) >= v_typo_threshold
      )
  ),
  enriched as (
    select
      m.*,
      (
        select b.price from public.books b
        where b.product_id = m.id
          and ((b.status = 'on_sale' and b.is_public = true)
          or (m.brand = '전일학원' and m.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = m.id and unsold.status = 'on_sale'
        )))
        order by b.price asc nulls last, b.id asc
        limit 1
      ) as book_price,
      (
        select b.condition_grade from public.books b
        where b.product_id = m.id
          and ((b.status = 'on_sale' and b.is_public = true)
          or (m.brand = '전일학원' and m.book_type = '모의고사'
        and b.status in ('reserved', 'settled')
        -- 숨긴 미판매 재고가 있으면 품절로 공개하지 않는다.
        and not exists (
          select 1 from public.books unsold
          where unsold.product_id = m.id and unsold.status = 'on_sale'
        )))
        order by b.price asc nulls last, b.id asc
        limit 1
      ) as book_condition_grade,
      (
        select count(*)::integer from public.books b
        where b.product_id = m.id
          and b.status = 'on_sale'
          and b.is_public = true
      ) as available_count
    from matched m
  )
  select
    e.id, e.title, e.option, e.subject, e.brand, e.book_type,
    e.published_year, e.instructor_name, e.cover_image_url, e.status,
    e.book_price as price,
    e.book_condition_grade as condition_grade,
    e.available_count,
    e.match_score
  from enriched e
  order by e.match_score desc, e.available_count desc, e.id desc
  limit greatest(p_limit, 1)
  offset greatest(p_offset, 0);
end;
$function$
;

-- books나 가격/주문 데이터는 수정하지 않고 파생 상태만 정합화한다.
-- 기존 product_status_logs 트리거가 상태 전이를 기록한다.
update public.products p set status=case
  when not p.is_listed then 'hidden'
  when exists(select 1 from public.books b where b.product_id=p.id and b.status='on_sale' and b.is_public) then 'selling'
  else 'sold_out'
end
where p.status is distinct from case
  when not p.is_listed then 'hidden'
  when exists(select 1 from public.books b where b.product_id=p.id and b.status='on_sale' and b.is_public) then 'selling'
  else 'sold_out'
end;

notify pgrst, 'reload schema';
commit;
