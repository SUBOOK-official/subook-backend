-- 권별 옵션명 개별 수정 (2026-07-23 운영자 피드백 후속)
--
-- 배경: 7/22 피드백 배치 C의 "옵션명 일괄 변경(from→to)"은 운영자 의도와 달랐음 —
--   원한 것은 책 하나하나의 옵션명을 세세하게 고치는 것. 수정 모달의 권별 카드에서
--   옵션을 직접 입력하고 저장 버튼으로 반영하는 흐름으로 전환한다.
--
-- 변경: admin_update_product_master의 p_books[] 항목에 선택 키 'option' 추가.
--   - 'option' 키가 있는 책만 그 값으로 갱신 (빈 문자열 → null = 옵션 없음)
--   - 실행 순서상 공통 필드 전파(1단계, 균일 시 옵션 전파)가 먼저 돌고 권별 루프(2단계)가
--     나중에 돌므로, 권별 입력값이 항상 최종 승리한다 — 전권 덮어쓰기 사고와 무관
--   - 시그니처 동일(CREATE OR REPLACE, 비파괴), 'option' 키 없는 구버전 payload는
--     기존과 완전히 동일하게 동작
--   (admin_rename_product_option은 DB에 유지하되 UI에서는 제거 — 권별 수정으로 대체)

begin;

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
  v_book_option text;
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

  -- 2) 권별 판매가/옵션명/상세사진 — 1단계 전파보다 뒤에 실행되어 권별 값이 최종 승리
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

    -- 권별 옵션명 (2026-07-23): 'option' 키가 있는 책만 갱신. 빈 값 = 옵션 없음(null).
    -- 옵션명은 실물 표기라 상태(판매완료/폐기 포함)와 무관하게 수정 허용.
    if v_book ? 'option' then
      v_book_option := nullif(btrim(coalesce(v_book->>'option', '')), '');
      update public.books set option = v_book_option where id = v_book_id;
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

notify pgrst, 'reload schema';

commit;
