-- 마이페이지 구매내역에서 '입금 대기(pending)' 주문의 입금 안내를 다시 보여주기 위해
-- get_my_orders가 shipping_recipient_name을 함께 반환하도록 한다.
--
-- 배경: 결제(계좌이체) 직후 주문완료 화면을 놓치면(탭 닫힘/세션 만료) 사용자가
--       입금 계좌·입금자명을 다시 볼 곳이 마이페이지 주문내역인데, 거기엔 입금 안내가
--       없었다. 입금자명은 admin 매칭과 동일하게 '수령인 성함 + 주문번호 숫자 4자리'여야
--       하므로 프로필 이름이 아니라 주문의 shipping_recipient_name이 반드시 필요하다.
--
-- 변경: get_my_orders 반환 JSON에 'shipping_recipient_name' 한 줄 추가.
--       (CREATE OR REPLACE — 비파괴. 나머지 본문은 20260525210000과 동일하게 유지하되
--        cover_image_url fallback도 그대로 보존.)

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
      -- ⬇ 입금 안내(입금자명 = 성함 + 주문번호 4자리) 재노출에 필요
      'shipping_recipient_name', o.shipping_recipient_name,
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
