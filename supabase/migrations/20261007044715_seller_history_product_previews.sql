-- 판매자 본인 수거 이력에 썸네일과 공개 상품 연결 정보를 추가한다.
-- 신규·병합 수거와 레거시 수거 모두 적용. 소유권 조건·RLS·기존 데이터는 유지.
-- 롤백: 함수의 product_id, cover_image_url JSON 필드 두 쌍만 제거한다.
DO $migration$
DECLARE
  definition text;
  old_fields constant text := $old$                'title', b.title,
$old$;
  new_fields constant text := $new$                'title', b.title,
                'product_id', case when exists (
                  select 1 from public.products p
                  where p.id = b.product_id and p.is_listed and exists (
                    select 1 from public.books visible where visible.product_id = p.id
                      and ((visible.status = 'on_sale' and visible.is_public = true)
                        or (p.brand = '전일학원' and p.book_type = '모의고사'
                          and visible.status in ('reserved', 'settled') and not exists (
                            select 1 from public.books unsold where unsold.product_id = p.id and unsold.status = 'on_sale'
                          )))
                  )
                ) then b.product_id end,
                'cover_image_url', coalesce(b.cover_image_url,
                  (select p.cover_image_url from public.products p where p.id = b.product_id)),
$new$;
BEGIN
  definition := pg_get_functiondef('public.get_my_pickup_requests(integer,integer)'::regprocedure);
  IF (length(definition) - length(replace(definition, old_fields, ''))) / length(old_fields) <> 2 THEN
    RAISE EXCEPTION 'Expected two seller book projections; inspect get_my_pickup_requests';
  END IF;
  EXECUTE replace(definition, old_fields, new_fields);
END;
$migration$;
