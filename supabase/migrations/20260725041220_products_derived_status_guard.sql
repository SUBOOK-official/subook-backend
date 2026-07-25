-- products.status 파생값 강제 가드
--
-- 배경(2026-07-25 드리프트 복구): products.status는 books(재고)에서 파생되는 값인데
--   (selling = 공개 판매중 재고 ≥1 / sold_out = 공개 재고는 있으나 판매중 0 / hidden = 공개 재고 0)
--   어드민 단건 토글(admin_set_product_status)이 books와 무관하게 값을 덮어써 드리프트가 생겼다.
--   실사례: 2026-07-22 19:30 KST 어드민에서 상품 4종(8·116·430·1324)을 수동 '품절' 전환 —
--   판매가능 재고가 있는데 3일간 sold_out으로 남음(이후 books 변경이 없으면 자동 복구 경로 없음).
--   반대 방향(공개 재고 0인데 selling) 4종(75·101·219·1166)도 같은 날 발견·정리함.
--   스토어 목록·상세 RPC는 books 기준이라 구매자 화면 영향은 없었지만, 어드민 화면
--   상태 뱃지·요약 카운트가 거짓이 되고 자동완성(status <> 'hidden' 필터)에 영향을 준다.
--
-- 설계:
-- - BEFORE UPDATE OF status 트리거로, status가 실제로 바뀌는 쓰기를 파생값으로 강제 수렴.
--   (books_refresh_storefront_product_status_trigger → refresh_storefront_product_status의
--   정상 쓰기는 이미 파생값이므로 동일값으로 그대로 통과한다.)
-- - 예외(RAISE)가 아니라 강제(coerce)를 택한 이유: 기존 RPC·일괄 스크립트를 중단시키지
--   않으면서 어떤 경로로 쓰든 재고 현실과 일치시키는 시스템 불변식이 목적.
-- - 상품을 스토어에서 내리려면 status가 아니라 books.is_public을 내릴 것
--   (단건 admin_set_book_visibility / 일괄 admin_bulk_set_products_visibility —
--   2026-07-22 일괄 노출/숨김 개편과 동일한 원칙).
-- - INSERT는 대상 아님: 등록 플로우가 상품 생성 직후 books를 넣으면서 books 트리거가
--   곧바로 정합화하고, 빈 상품의 초기 status는 실질 영향이 없다.

begin;

create or replace function public.products_enforce_derived_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_avail integer;
  v_pub integer;
begin
  if new.status is distinct from old.status then
    select
      count(*) filter (where b.status = 'on_sale' and b.is_public),
      count(*) filter (where b.is_public)
    into v_avail, v_pub
    from public.books b
    where b.product_id = new.id;

    new.status := case
      when v_avail > 0 then 'selling'
      when v_pub > 0 then 'sold_out'
      else 'hidden'
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists products_enforce_derived_status_trigger on public.products;
create trigger products_enforce_derived_status_trigger
  before update of status on public.products
  for each row
  execute function public.products_enforce_derived_status();

commit;
