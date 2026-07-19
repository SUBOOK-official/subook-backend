-- 상품 옵션 무결성: 권별 옵션이 서로 다른 상품에서 옵션이 뭉개지는 사고 차단 + 오염 정리
--
-- 배경(2026-07-19 운영 제보): 가이아 GAIA Final 주간지(권별 옵션 6/9/10/11주차) 상품의
--   수정 모달을 열었더니 옵션 칸에 "11주차"가 디폴트로 들어 있었다. 원인 체인:
--   1) refresh_storefront_product_status가 대표 book 1권의 option을 products.option에
--      계속 미러링 → 권별 옵션이 다른 상품에서도 products.option이 특정 권의 값으로 오염
--      (현재 오염 211개 상품 확인 — 공개 판매중 옵션이 2종 이상인데 option이 그중 하나)
--   2) 수정 모달이 products.option을 프리필하고, admin_update_product_master가 저장 시
--      소속 books "전체"의 option을 그 값으로 덮어씀 → 저장만 눌러도 6/9/10주차가 전부
--      11주차로 뭉개지는 구조 (시트 일련번호 대조 감사 결과 실제 피해는 아직 0건)
--
-- 변경 (CREATE OR REPLACE — 시그니처 동일, 비파괴):
--   1) refresh_storefront_product_status: 공개 판매중 books의 option이 균일할 때만
--      products.option 미러링. 서로 다르면 기존 값 유지 (단일 옵션 상품의 카드 표기는 종전대로).
--   2) admin_update_product_master: 소속 books 전체의 option이 균일할 때만 옵션 전파.
--      (식스샵 시절 단일 옵션 상품의 오타 일괄 수정 용도는 유지, 주간지류는 권별 옵션 보존)
--   3) 데이터 정리: 미러 오염된 products.option → null. group_key는 건드리지 않는다
--      (유니크 유지 — 옵션 참여 여부와 무관하게 키 안정성 우선).
--      공개 사이트는 book 단위 option_label만 사용하므로 구매자 화면 영향 없음.

begin;

-- ── 1) refresh_storefront_product_status: 옵션 미러는 균일할 때만 ─────────────

create or replace function public.refresh_storefront_product_status(p_product_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
  next_public_book_count integer;
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
    count(*) filter (where b.is_public)::integer,
    (count(distinct coalesce(b.option, '')) filter (where b.status = 'on_sale' and b.is_public)) <= 1
  into
    next_public_on_sale_count,
    next_public_book_count,
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
      when next_public_on_sale_count > 0 then 'selling'
      when next_public_book_count > 0 then 'sold_out'
      else 'hidden'
    end,
    updated_at = now()
  where p.id = p_product_id;
end;
$$;

-- ── 2) admin_update_product_master: 옵션 전파는 권별 옵션이 균일할 때만 ────────
-- (20260714064851 최신 정의 기반, option 전파 가드만 추가 — 시그니처 동일)

create or replace function public.admin_update_product_master(
  p_product_id bigint,
  p_title text,
  p_option text default null,
  p_original_price integer default null,
  p_cover_image_url text default null,
  p_books jsonb default '[]'::jsonb,
  p_subject text default null,
  p_brand text default null,
  p_book_type text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product record;
  v_title text;
  v_option text;
  v_cover text;
  v_new_group_key text;
  v_conflict_id bigint;
  v_book jsonb;
  v_book_id bigint;
  v_price integer;
  v_images text[];
  v_book_row record;
  v_updated_books integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_subject text;
  v_brand text;
  v_btype text;
  v_option_uniform boolean;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_title := nullif(btrim(coalesce(p_title, '')), '');
  if v_title is null then
    raise exception '상품 제목은 비울 수 없습니다.';
  end if;
  v_option := nullif(btrim(coalesce(p_option, '')), '');
  v_cover := nullif(btrim(coalesce(p_cover_image_url, '')), '');

  if p_original_price is not null and p_original_price <= 0 then
    raise exception '정가는 1원 이상이어야 합니다.';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id
  for update;

  if not found then
    raise exception '상품을 찾을 수 없습니다. (id: %)', p_product_id;
  end if;

  -- 카테고리: null/빈값이면 기존 값 유지 (변경 없음 — 구버전 프론트 하위호환)
  v_subject := coalesce(nullif(btrim(coalesce(p_subject, '')), ''), v_product.subject);
  v_brand := coalesce(nullif(btrim(coalesce(p_brand, '')), ''), v_product.brand);
  v_btype := coalesce(nullif(btrim(coalesce(p_book_type, '')), ''), v_product.book_type);

  -- 제목/옵션/카테고리가 바뀌면 group_key 재계산 + 중복 검사
  v_new_group_key := public.storefront_product_group_key(
    v_title, v_option, v_subject, v_brand, v_btype,
    v_product.published_year, v_product.instructor_name
  );

  select id into v_conflict_id
  from public.products
  where group_key = v_new_group_key
    and id <> p_product_id;

  if v_conflict_id is not null then
    raise exception '같은 제목/옵션/메타데이터 조합의 상품(#%)이 이미 존재합니다. 그 상품에서 수정하거나 제목을 다르게 입력하세요.', v_conflict_id;
  end if;

  -- 권별 옵션이 전부 같을 때만 옵션 전파 (2026-07-19: 주간지처럼 권별 옵션이 다른 상품을
  -- 상품 옵션 하나로 덮어쓰는 사고 차단. 단일 옵션 상품의 오타 일괄 수정은 종전대로 동작)
  select count(distinct coalesce(b.option, '')) <= 1
  into v_option_uniform
  from public.books b
  where b.product_id = p_product_id;

  -- 1) 소속 books 공통 필드 반영 (제목 + 균일 시 옵션 + 선택적으로 정가/커버)
  update public.books b
  set title = v_title,
      option = case when v_option_uniform then v_option else b.option end,
      -- 카테고리도 전파 — refresh_storefront_product_status가 대표 book 기준으로
      -- products를 되비추므로 books에 옛 값이 남으면 다음 book 변경 때 원복된다.
      subject = v_subject,
      brand = v_brand,
      book_type = v_btype,
      original_price = coalesce(p_original_price, b.original_price),
      cover_image_url = coalesce(v_cover, b.cover_image_url)
  where b.product_id = p_product_id;

  -- 2) 권별 판매가/상세사진
  for v_book in select * from jsonb_array_elements(coalesce(p_books, '[]'::jsonb)) loop
    v_book_id := (v_book->>'id')::bigint;
    if v_book_id is null then
      continue;
    end if;

    select id, status, price into v_book_row
    from public.books
    where id = v_book_id and product_id = p_product_id;

    if not found then
      v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '이 상품 소속이 아님');
      continue;
    end if;

    -- 판매가
    if v_book ? 'price' and v_book->>'price' is not null then
      v_price := (v_book->>'price')::integer;
      if v_price <= 0 then
        v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '판매가는 1원 이상');
      elsif v_book_row.status in ('settled', 'discarded') then
        if v_price <> coalesce(v_book_row.price, -1) then
          v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '정산완료/폐기 책의 가격은 변경 불가');
        end if;
      elsif v_price <> coalesce(v_book_row.price, -1) then
        update public.books set price = v_price where id = v_book_id;
        v_updated_books := v_updated_books + 1;
      end if;
    end if;

    -- 상세사진 (전달된 경우에만 교체 — 빈 배열이면 전체 삭제 의도로 처리)
    if v_book ? 'inspection_image_urls' and jsonb_typeof(v_book->'inspection_image_urls') = 'array' then
      select coalesce(array_agg(value), '{}'::text[])
      into v_images
      from jsonb_array_elements_text(v_book->'inspection_image_urls');

      update public.books set inspection_image_urls = v_images where id = v_book_id;
    end if;
  end loop;

  -- 3) products 마스터 반영 (books 트리거가 대표 book 기준으로 되비추지만,
  --    on_sale 공개 book이 없는 상품(품절/숨김)은 트리거가 coalesce로 기존 값을
  --    유지하므로 명시적으로 갱신해 둔다. group_key도 여기서만 갱신됨.)
  update public.products
  set title = v_title,
      option = v_option,
      subject = v_subject,
      brand = v_brand,
      book_type = v_btype,
      cover_image_url = coalesce(v_cover, cover_image_url),
      group_key = v_new_group_key,
      updated_at = now()
  where id = p_product_id;

  -- 대표 book 기준 상태/파생값 재계산
  perform public.refresh_storefront_product_status(p_product_id);

  return jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'updated_book_prices', v_updated_books,
    'option_propagated', v_option_uniform,
    'skipped', v_skipped
  );
end;
$$;

grant execute on function public.admin_update_product_master(bigint, text, text, integer, text, jsonb, text, text, text) to authenticated;

comment on function public.admin_update_product_master(bigint, text, text, integer, text, jsonb, text, text, text) is
  '상품 마스터 수정: 제목/정가/커버/카테고리는 product+소속 books 전파(+group_key 재계산). 옵션은 권별 옵션이 균일할 때만 books 전파(2026-07-19). 판매가·상세사진은 book별. settled/discarded 가격 보호.';

-- ── 3) 미러 오염 정리: 권별 옵션이 다른데 특정 권의 옵션이 박힌 products.option → null ──
-- group_key는 변경하지 않는다 (유니크 안정성). 공개 사이트는 products.option을 렌더하지
-- 않으므로(전부 book option_label 사용) 구매자 화면 영향 없음.

do $$
declare
  v_count integer;
begin
  update public.products p
  set option = null,
      updated_at = now()
  where p.option is not null
    and (
      select count(distinct coalesce(b.option, ''))
      from public.books b
      where b.product_id = p.id and b.status = 'on_sale' and b.is_public
    ) > 1
    and exists (
      select 1
      from public.books b
      where b.product_id = p.id and b.status = 'on_sale' and b.is_public
        and coalesce(b.option, '') = coalesce(p.option, '')
    );

  get diagnostics v_count = row_count;
  raise notice '미러 오염 products.option 정리: %건', v_count;
end $$;

notify pgrst, 'reload schema';

commit;
