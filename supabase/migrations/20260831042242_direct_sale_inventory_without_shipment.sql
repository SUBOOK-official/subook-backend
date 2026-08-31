-- 자체판매(직접 매입·출판사 직거래) 재고 지원 — books.shipment_id 옵션화 (2026-08-31)
--
-- 지금까지 books 는 반드시 수거 건(shipments)에 속해야 했다. 재고가 전부 위탁이었기
-- 때문. 전일학원 콜라보처럼 수거 없이 우리가 직접 확보하는 재고가 앞으로 계속 늘어나서
-- shipment_id 를 선택값으로 바꾼다. NULL = 자체판매 재고.
--
-- 영향 지점 전수 확인(2026-08-31) — 전부 null 안전인 것을 확인하고 진행:
--  · create_settlements_for_order : left join + `if v_item.shipment_id is not null`
--    → 셀러 정산이 생성되지 않는다 (자체판매는 지급할 셀러가 없으므로 의도된 동작)
--  · admin_get_product_inventory / admin_get_product_status_history : left join
--  · build_gsheet_inventory_rows : seller 조회가 0행 → '수거신청자' 공란
--  · lookup_seller_books / admin_search_register_targets : shipment 기준 조회라 자연 제외
--  · trg_books_auto_inspecting : 이미 WHEN (new.shipment_id IS NOT NULL) 로 가드됨
--  · books RLS : admin 정책뿐이고 shipment 를 참조하지 않음
--
-- 되돌리기: 자체판매 재고를 전부 지우거나 수거 건에 붙인 뒤
--   alter table public.books alter column shipment_id set not null;

begin;

alter table public.books alter column shipment_id drop not null;

comment on column public.books.shipment_id is
  '위탁 수거 건(shipments). 자체판매(직접 매입) 재고는 NULL — 셀러 정산이 생성되지 않는다.';

commit;
