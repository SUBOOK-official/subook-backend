-- FAQ 드래그 정렬 RPC + 고정 카테고리 재분류 (2026-07-14)
--
-- 배경(운영 요청):
--   1) FAQ 순서를 어드민에서 드래그로 조정 → 전체 순서를 원자적으로 저장할 RPC 필요.
--      (기존엔 편집 모달에서 display_order 숫자를 직접 입력)
--   2) 카테고리가 자유 입력이라 표기가 제각각(판매/안내/반품/구매 혼재, 오분류 존재).
--      고정 카테고리 6종으로 통일하고 기존 데이터를 내용 기준으로 재분류:
--      판매·수거 / 검수·등급 / 정산 / 구매·배송 / 반품·환불 / 서비스 안내
--      (canonical 목록은 admin-web AdminFaqsPage의 FAQ_CATEGORIES가 기준 —
--       서버 allowlist 검증은 두지 않음. 상품 카테고리와 동일 관례)
--
-- 답변 리치텍스트(HTML)는 스키마 변경 불필요 — answer text 컬럼에 HTML 문자열 저장,
-- 렌더/저장 새니타이즈는 프론트(shared-domain richText.js)가 담당.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 드래그 정렬 저장 RPC — 전달된 id 배열의 순번(1-base)대로 display_order 일괄 갱신
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_reorder_faqs(p_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_ids is null or array_length(p_ids, 1) is null then
    raise exception '정렬할 FAQ id 목록이 비어 있습니다.';
  end if;

  -- 배열 위치 = 새 display_order (1-base → CHECK(display_order >= 1) 충족)
  update public.faqs f
  set display_order = u.pos
  from unnest(p_ids) with ordinality as u(id, pos)
  where f.id = u.id;

  get diagnostics v_updated = row_count;

  return jsonb_build_object('success', true, 'updated', v_updated);
end;
$$;

grant execute on function public.admin_reorder_faqs(bigint[]) to authenticated;

comment on function public.admin_reorder_faqs(bigint[]) is
  'FAQ 드래그 정렬 저장: id 배열 순서(1-base)대로 display_order 일괄 갱신. (2026-07-14)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 기존 FAQ 카테고리 재분류 (프로덕션 데이터 기준, 내용 검토 후 매핑)
--    예외(내용상 재분류)를 먼저 id로 처리하고, 나머지는 구 카테고리명으로 일괄 매핑.
--    신규/타 환경 DB에서는 해당 행이 없어 no-op.
-- ─────────────────────────────────────────────────────────────────────────────

-- 예외: 기존 카테고리가 내용과 어긋나던 행 (id는 프로덕션 기준)
update public.faqs set category = '검수·등급' where id = 3;   -- S/A+ 등급 기준 (구: 안내)
update public.faqs set category = '검수·등급' where id = 5;   -- 검수 탈락 교재 처리 (구: 판매)
update public.faqs set category = '검수·등급' where id = 8;   -- 언제 판매 페이지 등록되나 — 검수 소요 안내 (구: 판매)
update public.faqs set category = '정산'       where id = 9;   -- 판매 대금 정산 시기 (구: 판매)
update public.faqs set category = '서비스 안내' where id = 10; -- 법적 구조 안내 (구: 반품 — 오분류)
update public.faqs set category = '반품·환불' where id = 12;  -- 단순 변심 반품 (구: 구매)

-- 일반 매핑: 남은 구 카테고리명 → 고정 카테고리
update public.faqs set category = '판매·수거'
  where category in ('판매', '수거');
update public.faqs set category = '구매·배송'
  where category in ('구매', '배송');
update public.faqs set category = '반품·환불'
  where category in ('반품', '환불');
update public.faqs set category = '검수·등급'
  where category in ('검수', '등급');
update public.faqs set category = '서비스 안내'
  where category in ('안내', '기타') or category is null;

commit;
