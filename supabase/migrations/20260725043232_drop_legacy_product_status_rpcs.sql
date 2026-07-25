-- 레거시 products.status 직접 쓰기 RPC 2종 폐기
--
-- 배경: 2026-07-25 products.status가 완전 파생값이 되면서
--   (20260725041220_products_derived_status_guard — BEFORE UPDATE 트리거가 모든
--   status 쓰기를 books 재고 파생값으로 강제 수렴) status를 직접 쓰는 RPC는
--   "success를 반환하지만 실제로는 아무 일도 안 하는" 거짓 성공 함수가 됐다.
--   이 거짓 성공이 2026-07-22 운영 사고(드롭다운 품절 전환 4종이 스토어에
--   미반영된 채 어드민 표시만 3일간 어긋남)의 원인 경로다. deprecated 주석 대신
--   drop을 택해, 남은 호출(배포 전에 열어둔 어드민 탭 등)이 조용히 성공하는 대신
--   시끄럽게 실패하도록 한다.
--
-- 호출처 정리 확인:
-- - admin_set_product_status: 상품 마스터 단건 상태 드롭다운이 유일한 호출처였고
--   2026-07-25 프론트에서 제거(읽기 전용 파생 뱃지 + is_public 공개/숨김 버튼으로 교체).
-- - admin_bulk_update_product_status: 2026-07-22 admin_bulk_set_products_visibility로
--   대체된 뒤 호출처 없음. backend/api(admin 미러)에도 두 함수 호출 없음.
--
-- 상품 올리기/내리기는 books.is_public 경로만 사용:
--   단건·일괄 admin_bulk_set_products_visibility / 권별 admin_set_book_visibility.
--
-- 롤백: 2026050606_admin_products_master_rpcs.sql(admin_set_product_status),
--   2026051509_admin_bulk_actions.sql(admin_bulk_update_product_status)의
--   원 정의 + grant를 재실행하면 복구된다.

begin;

drop function if exists public.admin_set_product_status(bigint, text);
drop function if exists public.admin_bulk_update_product_status(bigint[], text);

commit;

notify pgrst, 'reload schema';
