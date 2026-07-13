-- 마이페이지 구매내역 '상세보기' 시트(결제 정보)용 필드 확장.
--
-- 배경(2026-07-13 피드백): 주문내역 상세보기에서 쿠폰할인·결제일시를 확인할 수 없음.
--   orders에는 coupon_discount_amount(2026050603) / pg_approved_at(20260621000000)이
--   이미 기록되고 있으나 get_my_orders가 select하지 않아 프론트에서 항상 0원/주문일시로
--   대체 표시됐다. (admin 쪽은 20260707100500에서 동일 문제를 먼저 수정)
--
-- 변경: 반환 JSON에 coupon_discount_amount / applied_member_coupon_id / pg_approved_at 추가.
--   무통장입금은 입금확인 시각 컬럼이 없으므로 pg_approved_at은 PG 결제(토스 등)에서만 채워짐
--   — 프론트는 값이 없으면 '주문일시' 라벨로 폴백한다.
--
-- 본문은 20260601000000_get_my_orders_recipient_name.sql의 최신 정의에 필드 3종만 추가.
-- (CREATE OR REPLACE — 비파괴)

begin;

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
      -- 입금 안내(입금자명 = 성함 + 주문번호 4자리) 재노출에 필요
      'shipping_recipient_name', o.shipping_recipient_name,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      'discount_amount', o.discount_amount,
      -- ⬇ 상세보기 시트: 쿠폰할인 금액 + PG 결제 승인 시각 (2026-07-13)
      'coupon_discount_amount', o.coupon_discount_amount,
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'pg_approved_at', o.pg_approved_at,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'product_id', oi.product_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          -- ⚠ 식스샵 import 책은 oi.cover_image_url이 NULL — products fallback
          'cover_image_url', coalesce(
            nullif(btrim(oi.cover_image_url), ''),
            nullif(btrim(p.cover_image_url), '')
          ),
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price
        ) order by oi.id)
        from public.order_items oi
        left join public.products p on p.id = oi.product_id
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

commit;
