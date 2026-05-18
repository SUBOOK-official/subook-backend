-- 리뷰 시스템 전면 제거.
--
-- 배경:
--  - 출시 직전 단계에서 리뷰 기능을 보류하기로 결정.
--  - 2026041303_purchase_reviews.sql에서 만든 reviews 테이블, 인덱스, RLS,
--    트리거, storage 버킷, RPC 2종(create_product_review,
--    get_public_product_reviews), 그리고 get_my_orders 안의 reviews JOIN을
--    모두 정리한다.
--
-- 영향:
--  - public.reviews 테이블에 들어 있던 모든 리뷰 데이터가 영구 삭제된다
--    (실데이터가 운영 환경에 거의 없는 상태로, 사용자가 "다 없애도 돼"라고
--    명시적으로 확인).
--  - 프런트엔드의 publicReviews.js, ProductReviewsSection, ReviewComposer는
--    동일 변경 PR에서 함께 제거.

-- 1) RPC 제거 ---------------------------------------------------------------
drop function if exists public.create_product_review(bigint, integer, text, text[]);
drop function if exists public.get_public_product_reviews(bigint, text, integer, integer);

-- 2) get_my_orders 재정의 — reviews join 제거 ------------------------------
create or replace function public.get_my_orders(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      'discount_amount', o.discount_amount,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'product_id', oi.product_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price
        ) order by oi.id)
        from public.order_items oi
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    where o.user_id = v_user_id
    order by o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

-- 3) reviews 테이블 + 트리거/인덱스 제거 ------------------------------------
-- 일부 환경(특히 가장 오래된 프로덕션)에서는 reviews 테이블이 애초에 적용된
-- 적이 없을 수 있으므로, 트리거 drop은 table 존재 여부로 가드한다.
do $$
begin
  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'reviews' and c.relkind = 'r'
  ) then
    execute 'drop trigger if exists reviews_set_updated_at on public.reviews';
  end if;
end $$;

drop function if exists public.touch_reviews_updated_at();
drop table if exists public.reviews cascade;

-- 4) storage 'review-images' 버킷의 RLS 정책 제거 ---------------------------
-- Supabase는 SQL에서 storage.objects/storage.buckets 행을 직접 삭제하는 것을
-- 거부하므로(API/대시보드 사용), 여기서는 RLS 정책만 떼어낸다. 버킷 자체는
-- 사용하는 프런트엔드 코드가 사라졌으니 무해하게 비활성 상태로 남는다.
drop policy if exists "review_images_select_public" on storage.objects;
drop policy if exists "review_images_insert_own" on storage.objects;
drop policy if exists "review_images_update_own" on storage.objects;
drop policy if exists "review_images_delete_own" on storage.objects;
