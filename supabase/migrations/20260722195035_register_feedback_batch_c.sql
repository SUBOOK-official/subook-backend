-- 7/22 운영자 피드백 배치 C — 재고 관리: 옵션명 변경 · 하드 삭제 · 표지 교체 RPC
--
-- 1) admin_rename_product_option: 상품 내 특정 옵션명을 가진 권만 새 이름으로 rename.
--    증상(운영자): 재고 페이지에서 옵션 이름 수정이 불가 (2026-07-19 옵션 뭉개짐 사고
--    이후 옵션 편집 UI가 통째로 제거됨). from→to 매칭 방식이라 "상품 옵션 1개를 전 권에
--    덮어쓰기" 사고 패턴이 원천적으로 불가능하다. rename 후 옵션이 균일해지면 books 행
--    트리거(refresh_storefront_product_status)가 products.option 미러를 재계산한다.
--    order_items는 option_label을 자체 스냅샷하므로 과거 주문 표시에 영향 없음.
--
-- 2) admin_bulk_hard_delete_products: 주문·정산 이력이 없는 상품을 책과 함께 완전 삭제.
--    증상(운영자): 기존 admin_bulk_delete_products는 책이 1권이라도 연결돼 있으면 무조건
--    차단이라 사실상 아무것도 못 지움. FK 전수조사(2026-07-23) 결과 books를 RESTRICT로
--    참조하는 것은 order_items·settlements 둘뿐이고 products 참조는 전부 SET NULL/CASCADE.
--    → 보호 조건: 주문 이력(order_items), 정산 이력(settlements), 판매완료/폐기 책
--    (manual_settlements CASCADE로 식스샵 판매 기록이 지워지는 것 방지). 걸리면 그 상품은
--    skip하고 사유를 보고, 통과하면 books 삭제(cart/찜/재입고 알림은 CASCADE·SET NULL로
--    자동 정리) 후 products 삭제.
--
-- 3) admin_set_product_cover: 표지 AI 일괄 변환(재고 페이지 신규 액션)의 반영용.
--    products.cover_image_url만 바꾸면 books 행 트리거가 대표 책의 커버로 되돌리므로,
--    반드시 books.cover_image_url까지 함께 갱신한다 (표지는 책 종류 단위 자산).
--
-- (전부 신규 함수 — 비파괴. 구 admin_bulk_delete_products는 프론트에서 사용 중단.)

begin;

-- ── 1) 옵션명 변경 (from→to 매칭) ─────────────────────────────────────────────

create or replace function public.admin_rename_product_option(
  p_product_id bigint,
  p_from_option text,
  p_to_option text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from text;
  v_to text;
  v_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_from := nullif(btrim(coalesce(p_from_option, '')), '');
  v_to := nullif(btrim(coalesce(p_to_option, '')), '');

  if v_from is not distinct from v_to then
    raise exception '변경 전/후 옵션명이 같습니다.';
  end if;
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  -- 해당 옵션명을 가진 권만 rename (상태 무관 — 옵션명은 실물 표기라 전 권 일관 유지).
  -- 행 트리거가 products.option 미러·updated_at을 재계산한다.
  update public.books b
  set option = v_to
  where b.product_id = p_product_id
    and coalesce(btrim(b.option), '') = coalesce(v_from, '');
  get diagnostics v_count = row_count;

  if v_count = 0 then
    raise exception '옵션 ''%''를 가진 책이 없습니다.', coalesce(v_from, '(옵션 없음)');
  end if;

  return jsonb_build_object(
    'success', true,
    'renamed_count', v_count,
    'from_option', v_from,
    'to_option', v_to
  );
end;
$$;

grant execute on function public.admin_rename_product_option(bigint, text, text) to authenticated;

-- ── 2) 하드 삭제 (주문·정산 이력 보호) ────────────────────────────────────────

create or replace function public.admin_bulk_hard_delete_products(
  p_ids bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pid bigint;
  v_title text;
  v_reason text;
  v_deleted_products integer := 0;
  v_deleted_books integer := 0;
  v_book_count integer;
  v_skipped jsonb := '[]'::jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_ids is null or coalesce(array_length(p_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'deleted_products', 0, 'deleted_books', 0, 'skipped', '[]'::jsonb);
  end if;

  foreach v_pid in array p_ids
  loop
    select title into v_title from public.products where id = v_pid;
    if v_title is null then
      continue; -- 이미 없는 상품
    end if;

    -- 보호 조건 검사 (우선순위: 주문 > 정산 > 판매완료/폐기 책)
    v_reason := null;
    if exists (
      select 1 from public.order_items oi
      join public.books b on b.id = oi.book_id
      where b.product_id = v_pid
    ) or exists (
      select 1 from public.order_items oi where oi.product_id = v_pid
    ) then
      v_reason := '주문 이력 존재';
    elsif exists (
      select 1 from public.settlements s
      join public.books b on b.id = s.book_id
      where b.product_id = v_pid
    ) then
      v_reason := '정산 이력 존재';
    elsif exists (
      select 1 from public.books b
      where b.product_id = v_pid and b.status in ('settled', 'discarded')
    ) then
      v_reason := '판매완료/폐기 책 존재';
    end if;

    if v_reason is not null then
      v_skipped := v_skipped || jsonb_build_object('id', v_pid, 'title', v_title, 'reason', v_reason);
      continue;
    end if;

    -- 책 삭제 — cart_items·book_change_logs·manual_settlements는 CASCADE,
    -- restock_notifications.notified_book_id는 SET NULL로 자동 정리
    delete from public.books where product_id = v_pid;
    get diagnostics v_book_count = row_count;

    -- 상품 삭제 — purchase_reviews·wishlist_items·restock_notifications CASCADE,
    -- cart_items.product_id·order_items.product_id SET NULL (주문 이력은 위에서 차단됨)
    delete from public.products where id = v_pid;

    v_deleted_products := v_deleted_products + 1;
    v_deleted_books := v_deleted_books + v_book_count;
  end loop;

  return jsonb_build_object(
    'success', true,
    'deleted_products', v_deleted_products,
    'deleted_books', v_deleted_books,
    'skipped', v_skipped
  );
end;
$$;

grant execute on function public.admin_bulk_hard_delete_products(bigint[]) to authenticated;

-- ── 3) 표지 교체 (books까지 동기화 — 트리거 원복 방지) ────────────────────────

create or replace function public.admin_set_product_cover(
  p_product_id bigint,
  p_cover_image_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_book_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_url := nullif(btrim(coalesce(p_cover_image_url, '')), '');
  if v_url is null then
    raise exception '표지 이미지 URL이 비어 있습니다.';
  end if;
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  -- 표지는 책 종류 단위 자산 — 소속 전 권에 동일 적용 (행 트리거가 products에 재미러)
  update public.books set cover_image_url = v_url where product_id = p_product_id;
  get diagnostics v_book_count = row_count;

  update public.products
  set cover_image_url = v_url, updated_at = now()
  where id = p_product_id;

  return jsonb_build_object('success', true, 'book_count', v_book_count);
end;
$$;

grant execute on function public.admin_set_product_cover(bigint, text) to authenticated;

notify pgrst, 'reload schema';

commit;
