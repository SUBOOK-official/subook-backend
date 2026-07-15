-- 검수 워크스페이스 일괄 등급 지정 + 가격 보호 강화
--
-- 1) admin_bulk_update_books_grade(p_ids, p_grade)
--    선택한 책들의 condition_grade를 S/A_PLUS로 일괄 지정.
--    신규 입고 전량 S 디폴트 정책(2026-05-19)에서 권당 단축키 반복 입력을 대체.
--    DISCARD는 비가역 + status 부수효과가 있어 기존 admin_bulk_update_books_status
--    (확인 모달 + 사유 필수) 경로만 유지하고 여기서는 금지.
--    정산완료/폐기 책은 등급 이력 보호를 위해 제외.
--
-- 2) admin_bulk_update_books_price_delta 가격 보호
--    상품 마스터 모달(priceLocked)·수거 상세 판매가 편집기와 동일하게
--    settled/discarded 책을 일괄 가격 변경 대상에서 제외.
--    (정산완료 책 가격이 바뀌면 셀러가 조회하는 정산 명세 근거가 틀어짐)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 등급 일괄 지정
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_books_grade(
  p_ids bigint[],
  p_grade text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_grade is null or p_grade not in ('S', 'A_PLUS') then
    raise exception '등급은 S 또는 A_PLUS만 일괄 지정할 수 있습니다.';
  end if;

  update public.books
  set condition_grade = p_grade
  where id = any(p_ids)
    and status not in ('settled', 'discarded');

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object(
    'success', true,
    'updated_count', v_updated_count,
    'grade', p_grade
  );
end;
$$;

grant execute on function public.admin_bulk_update_books_grade(bigint[], text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 일괄 가격 ±% — 정산완료/폐기 보호 (기존 함수 재정의, 시그니처 동일)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_books_price_delta(
  p_ids bigint[],
  p_delta_percent numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
  v_factor numeric;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_delta_percent is null or p_delta_percent < -100 or p_delta_percent > 1000 then
    raise exception '할인/인상률은 -100 ~ 1000 사이여야 합니다.';
  end if;

  v_factor := 1 + (p_delta_percent / 100.0);

  update public.books
  set price = greatest(0, round(coalesce(price, 0) * v_factor)::integer)
  where id = any(p_ids)
    and price is not null
    and status not in ('settled', 'discarded');

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'updated_count', v_updated_count,
                            'delta_percent', p_delta_percent);
end;
$$;

grant execute on function public.admin_bulk_update_books_price_delta(bigint[], numeric) to authenticated;

commit;
