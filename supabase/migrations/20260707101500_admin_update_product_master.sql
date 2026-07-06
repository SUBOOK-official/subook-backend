-- 상품 마스터 수정 RPC (제목/옵션/정가/대표사진 + 인스턴스별 판매가/상세사진).
--
-- 운영 피드백(2026-07-06): 등록된 상품의 제목/가격/사진을 수정하는 기능이 없음.
--
-- 설계 배경:
--   · 스토어 노출 필드는 books가 원본이다 — refresh_storefront_product_status 트리거가
--     "대표 book"의 title/option/cover 등을 products에 되비추고(2026040709), 스토어
--     RPC도 coalesce(book.cover, product.cover)로 book 우선이다. 따라서 제목/옵션/커버는
--     products 행만 고치면 다음 book 변경 때 원복된다 → 소속 books 전체에 함께 반영한다.
--   · 판매가(price)·상세사진(inspection_image_urls)은 물리적 한 권(book)의 속성이라
--     book별로 개별 수정한다.
--   · settled(정산완료)·discarded 책의 판매가는 변경 금지 — 레거시 셀러 조회
--     (seller-lookup)가 books.price로 정산액을 계산·표시하므로 이력이 왜곡된다.
--   · 제목/옵션이 바뀌면 products.group_key(메타데이터 해시)를 재계산한다. 동일 조합의
--     다른 상품이 이미 있으면 명확한 에러로 거부 (상품 병합은 별도 운영 절차).

begin;

create or replace function public.admin_update_product_master(
  p_product_id bigint,
  p_title text,
  p_option text default null,
  p_original_price integer default null,
  p_cover_image_url text default null,
  p_books jsonb default '[]'::jsonb
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

  -- 제목/옵션이 바뀌면 group_key 재계산 + 중복 검사
  v_new_group_key := public.storefront_product_group_key(
    v_title, v_option, v_product.subject, v_product.brand, v_product.book_type,
    v_product.published_year, v_product.instructor_name
  );

  select id into v_conflict_id
  from public.products
  where group_key = v_new_group_key
    and id <> p_product_id;

  if v_conflict_id is not null then
    raise exception '같은 제목/옵션/메타데이터 조합의 상품(#%)이 이미 존재합니다. 그 상품에서 수정하거나 제목을 다르게 입력하세요.', v_conflict_id;
  end if;

  -- 1) 소속 books 공통 필드 반영 (제목/옵션 + 선택적으로 정가/커버)
  update public.books b
  set title = v_title,
      option = v_option,
      original_price = coalesce(p_original_price, b.original_price),
      cover_image_url = coalesce(v_cover, b.cover_image_url)
  where b.product_id = p_product_id;

  -- 2) 인스턴스별 판매가/상세사진
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
    'skipped', v_skipped
  );
end;
$$;

grant execute on function public.admin_update_product_master(bigint, text, text, integer, text, jsonb) to authenticated;

comment on function public.admin_update_product_master(bigint, text, text, integer, text, jsonb) is
  '상품 마스터 수정: 제목/옵션/정가/커버는 product+소속 books 전파(+group_key 재계산), 판매가·상세사진은 book별. settled/discarded 가격 보호. (2026-07-06 피드백)';

commit;
