-- 마이페이지 구매내역에 품목별 환불 상태 노출 (2026-08-01 품목별 부분환불 후속)
--
-- 배경: 20260731174237로 부분환불이 도입되며 order_items.refunded_at/refund_amount와
--   orders.refunded_amount가 생겼지만 get_my_orders가 select하지 않아, 부분환불된
--   주문도 구매자 마이페이지에서는 아무 표시가 없었다 (주문 status는 유지되므로).
--
-- 변경: 반환 JSON에 3필드 추가 (CREATE OR REPLACE — 비파괴, 시그니처 동일):
--   - 주문: refunded_amount (환불 누계 — 상세보기 시트의 환불 금액 행)
--   - 품목: refunded_at / refund_amount (구매 카드의 '환불 완료' 칩)
--
-- 본문은 20260713042357의 최신 정의 기반. (⚠ 재정의 시 paid_at·쿠폰 필드·
--   식스샵 cover_image_url fallback 유지 필수)

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
      -- 상세보기 시트: 쿠폰할인 금액 + 결제 확인 시각 (2026-07-13)
      'coupon_discount_amount', o.coupon_discount_amount,
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'paid_at', o.paid_at,
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
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 부분환불이면 status 유지 + 이 값만 증가)
      'refunded_amount', o.refunded_amount,
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
          'total_price', oi.total_price,
          -- 품목별 환불 상태 (2026-08-01 부분환불)
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount
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

notify pgrst, 'reload schema';
