-- 전체 출고 대기 스마트 출력 + 페이지네이션 전 책 제목 검색(P1).
-- 데이터 변경/RLS 완화 없음. 롤백: 이전 앱과 list_admin_work_orders 정의로 복귀.
begin;
-- 운영 화면 개편: 신규 읽기 RPC와 관리자 전용 작업 기록. 결제/환불/정산 처리 함수는 변경하지 않는다.
CREATE OR REPLACE FUNCTION public.list_admin_work_orders(p_search text DEFAULT NULL::text, p_statuses text[] DEFAULT NULL::text[], p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_view text DEFAULT 'all', p_user_id uuid DEFAULT NULL, p_order_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_items jsonb;
  v_total integer;
begin
  if not coalesce(public.is_admin_user(), false) then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
  from public.orders o
  left join public.member_profiles p on p.user_id = o.user_id
  where
    (p_search is null or p_search = '' or
      o.order_number ilike '%' || p_search || '%' or
      p.name ilike '%' || p_search || '%' or
      p.email ilike '%' || p_search || '%' or
      p.phone ilike '%' || p_search || '%' or
      o.shipping_recipient_name ilike '%' || p_search || '%' or
      o.shipping_recipient_phone ilike '%' || p_search || '%' or
      exists (select 1 from public.order_items search_item
        where search_item.order_id = o.id and search_item.title ilike '%' || p_search || '%'))
    and (p_user_id is null or o.user_id = p_user_id)
    and (p_order_id is null or o.id = p_order_id)
    and (
      p_view = 'all'
      or (p_view = 'fulfillment' and o.status in ('paid','preparing') and (o.refund_requested_at is null or o.refund_request_resolved_at is not null))
      or (p_view = 'refunds' and o.refund_requested_at is not null and o.refund_request_resolved_at is null and o.status <> 'refunded')
      or (p_view = 'returns' and o.return_registered_at is not null and o.return_recovered_at is null)
      or (p_view = 'restock' and exists(select 1 from public.order_items held where held.order_id = o.id and held.restock_held_at is not null))
    )
    and (p_statuses is null or o.status = any(p_statuses))
    and (p_from_date is null or o.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul'))
    and (p_to_date is null or o.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul'));

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      -- 결제 확인 시각 2종 (2026-07-13: 무통장=paid_at, 레거시 PG=pg_approved_at 폴백)
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      -- 할인 필드 3종 (2026-07-06 피드백: 주문 상세에 쿠폰 사용액 표시)
      'discount_amount', o.discount_amount,
      'coupon_discount_amount', o.coupon_discount_amount,
      -- 포인트 사용액 (2026-09-02 포인트 제도 — total_amount에 이미 차감 반영)
      'points_used', coalesce(o.points_used, 0),
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'shipping_recipient_name', o.shipping_recipient_name,
      'shipping_recipient_phone', o.shipping_recipient_phone,
      'shipping_postal_code', o.shipping_postal_code,
      'shipping_address_line1', o.shipping_address_line1,
      'shipping_address_line2', o.shipping_address_line2,
      'shipping_memo', o.shipping_memo,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      -- 환불 메타 4종
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      -- 환불 신청 해소 시각 (2026-08-24 자동확정 보류 — null이면 확정·송금 보류 중)
      'refund_request_resolved_at', o.refund_request_resolved_at,
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- 반품 수거 3종 (2026-08-24 반품 수거 자동화 — cust_use_no는 서버 전용이라 미노출)
      'return_tracking_number', o.return_tracking_number,
      'return_registered_at', o.return_registered_at,
      'return_recovered_at', o.return_recovered_at,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      -- 비회원 주문 여부 (2026-08-03 게스트 주문 도입)
      'is_guest', (o.user_id is null),
      'buyer_email', p.email,
      'buyer_name', p.name,
      'buyer_phone', p.phone,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          -- 품목별 환불 상태 (2026-08-01 부분환불)
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount,
          'refund_reason', oi.refund_reason,
          -- 재입고 보류 (2026-08-24 반품 수거 — 실물 회수 전 재노출 방지)
          'restock_held_at', oi.restock_held_at,
          -- 피킹 동선용 재고 메타 (2026-07-18: 위치로 가서 일련번호로 실물 확인)
          'book_serial_number', b.serial_number,
          'book_location', b.location,
          'book_status', b.status,
          -- 수북 자체 판매 교재 품목은 위치·일련번호가 없는 게 정상 (2026-09-15)
          'product_id', oi.product_id,
          'is_direct_sale', exists (select 1 from public.direct_sale_products ds where ds.product_id = oi.product_id)
        ) order by oi.id)
        from public.order_items oi
        left join public.books b on b.id = oi.book_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    left join public.member_profiles p on p.user_id = o.user_id
    where
      (p_search is null or p_search = '' or
        o.order_number ilike '%' || p_search || '%' or
        p.name ilike '%' || p_search || '%' or
        p.email ilike '%' || p_search || '%' or
        p.phone ilike '%' || p_search || '%' or
        o.shipping_recipient_name ilike '%' || p_search || '%' or
        o.shipping_recipient_phone ilike '%' || p_search || '%' or
      exists (select 1 from public.order_items search_item
        where search_item.order_id = o.id and search_item.title ilike '%' || p_search || '%'))
      and (p_user_id is null or o.user_id = p_user_id)
    and (p_order_id is null or o.id = p_order_id)
    and (
      p_view = 'all'
      or (p_view = 'fulfillment' and o.status in ('paid','preparing') and (o.refund_requested_at is null or o.refund_request_resolved_at is not null))
      or (p_view = 'refunds' and o.refund_requested_at is not null and o.refund_request_resolved_at is null and o.status <> 'refunded')
      or (p_view = 'returns' and o.return_registered_at is not null and o.return_recovered_at is null)
      or (p_view = 'restock' and exists(select 1 from public.order_items held where held.order_id = o.id and held.restock_held_at is not null))
    )
    and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul'))
      and (p_to_date is null or o.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul'))
    order by
      -- 미해소 환불 신청 최우선 (해소된 신청은 일반 정렬)
      (case
        when o.refund_requested_at is not null
         and o.refund_request_resolved_at is null
         and o.status <> 'refunded' then 0
        else 1
      end),
      o.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(coalesce(p_offset, 0), 0)
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;
REVOKE ALL ON FUNCTION public.list_admin_work_orders(text,text[],date,date,integer,integer,text,uuid,bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.list_admin_work_orders(text,text[],date,date,integer,integer,text,uuid,bigint) TO authenticated;


-- service_role 전용. 관리자 JWT를 검증한 cj-delivery API에서만 사용한다.
create function public.admin_plan_pending_order_deliveries() returns jsonb
language sql stable security definer set search_path = public as $$
  with pending as (
    select o.id, o.order_number, public.delivery_match_key(o) as match_key,
      case
        when o.refund_requested_at is not null and o.refund_request_resolved_at is null then '환불 신청 처리 중'
        when not exists(select 1 from order_items i where i.order_id=o.id and i.refunded_at is null) then '발송할 품목 없음'
        when exists(select 1 from order_delivery_group_members m join order_delivery_groups g on g.id=m.group_id
          where m.order_id=o.id and (g.state in ('booking','registered')
            or (g.state='claimed' and g.updated_at>now()-interval '10 minutes'))) then '기존 송장 접수 결과 확인 필요'
        else null
      end as reason
    from public.orders o
    where o.status in ('preparing','paid') and nullif(btrim(o.tracking_number),'') is null
  ), grouped as (
    select array_agg(id order by id) as ids from pending where reason is null group by match_key
  )
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(to_jsonb(ids) order by ids[1]) from grouped),'[]'::jsonb),
    'heldOrders', coalesce((select jsonb_agg(jsonb_build_object('id',id,'order_number',order_number,'reason',reason) order by id)
      from pending where reason is not null),'[]'::jsonb)
  );
$$;
revoke all on function public.admin_plan_pending_order_deliveries() from public, anon, authenticated;
grant execute on function public.admin_plan_pending_order_deliveries() to service_role;

commit;
