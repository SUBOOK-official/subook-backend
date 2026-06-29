-- 상품 등록 플로우 재설계 (Frame 2~4 프로토타입 기반).
--   1) books에 할인 방식/값 컬럼 추가 (정가/정액/정률) — 추가형(비파괴)
--   2) 등록용 교재 검색 RPC (옵션/정가/재고 집계 포함)
--   3) 고객(수거) 단위 통합 등록 RPC (신규 교재 + 기존 교재 재고 추가)
--
-- 설계 메모:
--   - 교재 = products(카탈로그), 재고/권 = books(1권=1row), 고객 = shipments(소유)
--   - 신규 교재 메타데이터(과목/브랜드/타입/연도/강사)는 상품명 문자열에서 자동 파싱
--     (2026051202 선례 재사용), 못 찾으면 '기타'/'개념'. 추후 상품 마스터에서 수정.
--   - 판매가 = 정가 기준 할인 계산 후 books.price에 저장 (스토어/정산은 price만 읽음)
--   - 등급은 전부 'S'(신규 입고 정책), 공개 여부는 호출측 토글(is_public)

-- ── 1) 할인 컬럼 (additive) ───────────────────────────────────────────
alter table public.books
  add column if not exists discount_type text null
    check (discount_type is null or discount_type in ('none', 'amount', 'rate')),
  add column if not exists discount_value integer null
    check (discount_value is null or discount_value >= 0);

comment on column public.books.discount_type is '할인 방식: none(정가) / amount(정액,원) / rate(정률,%)';
comment on column public.books.discount_value is '할인 값: amount면 할인 금액(원), rate면 할인율(%, 0~100)';

-- ── 2) 내부 헬퍼: 상품명 → 메타 추정 (2026051202 로직 일반화) ─────────
create or replace function public._register_infer_product_meta(p_title text)
returns table(year integer, brand text, subject text, book_type text, instructor text)
language sql
immutable
as $$
  select
    nullif((regexp_match(coalesce(p_title, ''), '^(\d{4})'))[1], '')::integer as year,
    case
      when p_title like '%상상국어평가연구소%' then '상상국어평가연구소'
      when p_title like '%시대인재%' then '시대인재'
      when p_title like '%강남대성%' then '강남대성'
      when p_title like '%대성마이맥%' then '대성마이맥'
      when p_title ~ '\m대성\M' then '대성마이맥'
      when p_title like '%이투스%' then '이투스'
      when p_title like '%메가스터디%' then '메가스터디'
      when p_title like '%이감%' then '이감'
      when p_title like '%EBS%' then 'EBS'
      else '기타'
    end as brand,
    case
      when p_title ~ '(생명과학|물리|화학|지구과학|과학탐구)' then '과학'
      when p_title ~ '(사회문화|경제|정치|한국지리|세계지리|윤리|동아시아사|세계사|사탐|사회탐구)' then '사회'
      when p_title ~ '한국사' then '한국사'
      when p_title ~ '(미적분|확률과\s*통계|기하|수학)' then '수학'
      when p_title ~ '(독서|문학|언어와\s*매체|언어와매체|화법과\s*작문|매체\s*N제|국어)' then '국어'
      when p_title ~ '영어' then '영어'
      else '기타'
    end as subject,
    case
      when p_title ~ '모의고사' then '모의고사'
      when p_title ~ '주간지' then '주간지'
      when p_title ~ '기출' then '기출'
      when p_title ~ 'N제' then 'N제'
      when p_title ~ '워크북' then '워크북'
      when p_title ~ '논술' then '논술'
      when p_title ~ '내신' then '내신'
      when p_title ~ 'EBS' then 'EBS'
      when p_title ~ '(크럭스|CRUX|블리츠|BLITZ|아폴로|Apollo|리마인더|RE-?MINDER)' then 'N제'
      when p_title ~ '환생' then '모의고사'
      else '개념'
    end as book_type,
    (regexp_match(coalesce(p_title, ''), '([가-힣]{2,4})T(?:\s|$)'))[1] as instructor
$$;

-- ── 2b) 내부 헬퍼: 정가 + 할인 → 판매가 ──────────────────────────────
create or replace function public._register_compute_price(
  p_original integer, p_type text, p_value integer
)
returns integer
language sql
immutable
as $$
  select case
    when p_original is null then null
    when p_type = 'amount' and p_value is not null then greatest(0, p_original - p_value)
    when p_type = 'rate' and p_value is not null
      then greatest(0, round(p_original * (1 - least(greatest(p_value, 0), 100)::numeric / 100)))::integer
    else p_original
  end
$$;

-- ── 3) 등록용 교재 검색 (Frame 2 좌측 / Frame 3 옵션 집계) ────────────
create or replace function public.admin_search_products_for_register(
  p_search text default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_search text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_search := nullif(btrim(coalesce(p_search, '')), '');
  if v_search is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'title'), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', p.id,
      'title', p.title,
      'option', p.option,
      'subject', p.subject,
      'brand', p.brand,
      'book_type', p.book_type,
      'published_year', p.published_year,
      'instructor_name', p.instructor_name,
      'cover_image_url', p.cover_image_url,
      'representative_original_price', agg.rep_original,
      'representative_grade', coalesce(
        (select mode() within group (order by b2.condition_grade)
         from public.books b2 where b2.product_id = p.id and b2.status = 'on_sale'),
        'S'
      ),
      'inventory_count', coalesce(agg.stock_total, 0),
      'options', coalesce(agg.options, '[]'::jsonb)
    ) as row_data
    from public.products p
    left join lateral (
      select
        sum(g.cnt) as stock_total,
        max(g.max_original) as rep_original,
        jsonb_agg(jsonb_build_object(
          'option', g.option,
          'stock_count', g.cnt,
          'price', g.min_price,
          'original_price', g.max_original
        ) order by g.option nulls first) as options
      from (
        select b.option, count(*) as cnt, min(b.price) as min_price, max(b.original_price) as max_original
        from public.books b
        where b.product_id = p.id and b.status = 'on_sale'
        group by b.option
      ) g
    ) agg on true
    where (
      p.title ilike '%' || v_search || '%'
      or coalesce(p.instructor_name, '') ilike '%' || v_search || '%'
      or coalesce(p.option, '') ilike '%' || v_search || '%'
    )
    order by p.title
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) sub;

  return v_result;
end;
$$;

-- ── 4) 고객(수거) 단위 통합 등록 ────────────────────────────────────
-- p_payload = {
--   "new_products": [
--     { "title","original_price","discount_type","discount_value","option"(콤마분리),
--       "cover_image_url","inspection_image_urls":[...], "is_public" }
--   ],
--   "existing_additions": [
--     { "product_id","cover_image_url","inspection_image_urls":[...], "is_public",
--       "options":[ { "option","quantity","price","original_price"?,"discount_type"?,"discount_value"? } ] }
--   ]
-- }
create or replace function public.admin_register_customer_inventory(
  p_shipment_id bigint,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_opt jsonb;
  v_meta record;
  v_prod record;
  v_group_key text;
  v_product_id bigint;
  v_existing_id bigint;
  v_title text;
  v_original integer;
  v_dtype text;
  v_dvalue integer;
  v_price integer;
  v_cover text;
  v_details text[];
  v_is_public boolean;
  v_qty integer;
  v_optname text;
  v_i integer;
  v_rep_original integer;
  v_options text[];
  v_created_products integer := 0;
  v_created_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from public.shipments where id = p_shipment_id) then
    raise exception '고객(수거) 정보를 찾을 수 없습니다.';
  end if;

  -- ── 신규 교재 ──────────────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'new_products', '[]'::jsonb))
  loop
    v_title := nullif(btrim(v_item->>'title'), '');
    if v_title is null then
      continue;
    end if;

    v_original := nullif(btrim(coalesce(v_item->>'original_price', '')), '')::integer;
    v_dtype := coalesce(nullif(v_item->>'discount_type', ''), 'none');
    v_dvalue := nullif(btrim(coalesce(v_item->>'discount_value', '')), '')::integer;
    v_price := public._register_compute_price(v_original, v_dtype, v_dvalue);
    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;
    v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;

    select * into v_meta from public._register_infer_product_meta(v_title);
    v_group_key := public.storefront_product_group_key(
      v_title, null, v_meta.subject, v_meta.brand, v_meta.book_type, v_meta.year, v_meta.instructor
    );

    select id into v_existing_id from public.products where group_key = v_group_key;
    if v_existing_id is null then
      insert into public.products (
        group_key, title, option, subject, brand, book_type,
        published_year, instructor_name, cover_image_url, status
      ) values (
        v_group_key, v_title, null, v_meta.subject, v_meta.brand, v_meta.book_type,
        v_meta.year, v_meta.instructor, v_cover, 'selling'
      ) returning id into v_product_id;
      v_created_products := v_created_products + 1;
    else
      v_product_id := v_existing_id;
      if v_cover is not null then
        update public.products
        set cover_image_url = coalesce(cover_image_url, v_cover), updated_at = now()
        where id = v_product_id;
      end if;
    end if;

    v_options := array(
      select btrim(x) from regexp_split_to_table(coalesce(v_item->>'option', ''), ',') x
      where btrim(x) <> ''
    );
    if array_length(v_options, 1) is null then
      v_options := array[null]::text[];
    end if;

    foreach v_optname in array v_options
    loop
      insert into public.books (
        shipment_id, title, option, product_id, original_price, price, condition_grade,
        cover_image_url, inspection_image_urls, status, is_public,
        discount_type, discount_value, inspected_at
      ) values (
        p_shipment_id, v_title, nullif(v_optname, ''), v_product_id, v_original, v_price, 'S',
        v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
        v_dtype, v_dvalue, now()
      );
      v_created_books := v_created_books + 1;
    end loop;
  end loop;

  -- ── 기존 교재 재고 추가 ────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'existing_additions', '[]'::jsonb))
  loop
    v_product_id := nullif(btrim(coalesce(v_item->>'product_id', '')), '')::bigint;
    if v_product_id is null then
      continue;
    end if;

    select * into v_prod from public.products where id = v_product_id;
    if not found then
      continue;
    end if;

    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;

    select max(original_price) into v_rep_original
    from public.books where product_id = v_product_id and status = 'on_sale';

    if v_cover is not null and v_prod.cover_image_url is null then
      update public.products set cover_image_url = v_cover, updated_at = now() where id = v_product_id;
    end if;

    for v_opt in
      select value from jsonb_array_elements(coalesce(v_item->'options', '[]'::jsonb))
    loop
      v_qty := coalesce(nullif(btrim(coalesce(v_opt->>'quantity', '')), '')::integer, 0);
      if v_qty < 1 then
        continue;
      end if;
      v_optname := nullif(btrim(coalesce(v_opt->>'option', '')), '');
      v_price := nullif(btrim(coalesce(v_opt->>'price', '')), '')::integer;
      v_original := coalesce(nullif(btrim(coalesce(v_opt->>'original_price', '')), '')::integer, v_rep_original);
      v_dtype := coalesce(nullif(v_opt->>'discount_type', ''), 'none');
      v_dvalue := nullif(btrim(coalesce(v_opt->>'discount_value', '')), '')::integer;
      v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;

      for v_i in 1..v_qty
      loop
        insert into public.books (
          shipment_id, title, option, product_id, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at
        ) values (
          p_shipment_id, v_prod.title, v_optname, v_product_id, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now()
        );
        v_created_books := v_created_books + 1;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object(
    'success', true,
    'created_products', v_created_products,
    'created_books', v_created_books
  );
end;
$$;

grant execute on function public.admin_search_products_for_register(text, integer) to authenticated;
grant execute on function public.admin_register_customer_inventory(bigint, jsonb) to authenticated;
