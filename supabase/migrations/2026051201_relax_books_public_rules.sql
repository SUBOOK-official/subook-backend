-- books_enforce_public_storefront_rules 완화.
--
-- 배경: 위탁판매 모델로 전환하면서 노출 메타데이터(브랜드/유형/연도/이미지/...)는
-- products 마스터가 책임지고, books는 인스턴스(가격/등급/판매상태)만 본다.
-- 기존 트리거는 books에 12개 필드를 NOT NULL로 강제했는데, 식스샵 마이그레이션으로
-- 들어온 카탈로그 데이터는 그 파이프라인을 거치지 않아 메타데이터가 비어있어 노출 불가였음.
--
-- 새 규칙:
--   - status != 'on_sale'이면 is_public=false (product_id 연결은 유지 — history)
--   - is_public=true 조건:
--       status = 'on_sale'
--       product_id IS NOT NULL  (products 마스터에 연결되어야 노출)
--       title, price, condition_grade NOT NULL
--   - 기존의 storefront_product_group_key 자동 생성 / products auto-upsert 로직 제거
--     (어드민이 products 마스터를 직접 관리하는 위탁판매 모델)

create or replace function public.books_enforce_public_storefront_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 판매 중이 아니면 무조건 비노출 (product_id 연결은 유지: 위탁 히스토리)
  if new.status is distinct from 'on_sale' then
    new.is_public := false;
    return new;
  end if;

  -- is_public=true일 때 최소 조건만 검사
  if coalesce(new.is_public, false) then
    if new.product_id is null then
      raise exception 'Public books must be linked to a product master.';
    end if;

    if nullif(btrim(coalesce(new.title, '')), '') is null then
      raise exception 'Public books require a title.';
    end if;

    if new.price is null then
      raise exception 'Public books require a sale price.';
    end if;

    if nullif(btrim(coalesce(new.condition_grade, '')), '') is null then
      raise exception 'Public books require a condition grade.';
    end if;
  end if;

  return new;
end;
$$;
