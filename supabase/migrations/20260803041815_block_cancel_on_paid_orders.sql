-- 결제 완료 주문의 '주문취소'(상태변경) 차단 — 환불 없는 취소·거짓 refunded 표기 제거
--
-- 문제(2026-08-03 발견): admin_update_order_status가
--   1) 결제된(paid_at 有) 주문도 cancelled로 전이시키면서 PG 취소를 호출하지 않았고
--   2) payment_status를 실제 환불 없이 'paid'→'refunded'로 표기했다(거짓 장부 —
--      refunded_at/refunded_amount는 비어 있는데 상태만 환불됨).
--   실사고: ORD-2607-0019(무통장 14,400원, 입금확인 후 주문취소 — 환불 기록 0원),
--           ORD-2608-0061/0062(카드 테스트, 어드민 취소 눌렀지만 PG 환불 안 됨).
--   구매자 셀프 취소는 20260724093222에서 같은 이유로 pending 전용으로 제한했으나
--   어드민 경로가 그대로 남아 있었다.
--
-- 정책: 취소 = 결제 전에 죽은 주문 / 환불 = 결제 후 되돌린 주문.
--   결제된 주문의 취소는 '환불처리'(payment-cancel.js → admin_refund_order_items)로
--   단일화 — PG 실취소·재고 복원·쿠폰 복구·정산 처리·알림톡까지 한 흐름.
--
-- 변경(CREATE OR REPLACE, 비파괴):
--   · cancelled 전이는 미결제 주문만 허용 (paid_at 없고 payment_status도 'paid'가 아닐 때).
--   · 거짓 refunded 플립 제거 — cancelled 전이 시 payment_status는 그대로 둔다.
--   · admin_bulk_update_order_status는 본 함수를 loop 호출하므로 자동으로 같이 막힌다.
--   · 유지(재정의 시 필수): is_admin_user 가드, 상태 전이 검증, books 복원(on_sale +
--     is_public=true), 쿠폰 복구, tracking/confirmed_at/auto_confirm_at 로직.
--     (base: 20260525200000 — 프로덕션 정의와 일치 확인 후 재정의)

begin;

create or replace function public.admin_update_order_status(
  p_order_id bigint,
  p_status text,
  p_tracking_number text default null,
  p_tracking_carrier text default 'CJ대한통운'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_status not in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed', 'cancelled') then
    raise exception 'Invalid status: % (허용: paid/preparing/shipping/delivered/confirmed/cancelled)', p_status;
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found';
  end if;

  if p_status = 'paid' then
    if v_order.status not in ('pending') then
      raise exception 'Cannot mark as paid from status: %', v_order.status;
    end if;
  elsif p_status = 'preparing' then
    if v_order.status not in ('paid') then
      raise exception 'Cannot mark as preparing from status: %', v_order.status;
    end if;
  elsif p_status = 'shipping' then
    if v_order.status not in ('paid', 'preparing') then
      raise exception 'Cannot mark as shipping from status: %', v_order.status;
    end if;
  elsif p_status = 'delivered' then
    if v_order.status not in ('shipping') then
      raise exception 'Cannot mark as delivered from status: %', v_order.status;
    end if;
  elsif p_status = 'confirmed' then
    if v_order.status not in ('delivered') then
      raise exception 'Cannot mark as confirmed from status: %. 환불은 admin_refund_order를 사용하세요.', v_order.status;
    end if;
  elsif p_status = 'cancelled' then
    if v_order.status not in ('pending', 'paid', 'preparing') then
      raise exception 'Cannot cancel from status: %. 배송 시작 이후는 환불처리를 사용하세요.', v_order.status;
    end if;
    -- 결제된 주문은 상태변경 취소 금지 — 돈이 움직이지 않는 취소는 거짓 장부가 된다.
    if v_order.paid_at is not null or v_order.payment_status = 'paid' then
      raise exception '결제가 완료된 주문은 주문취소로 처리할 수 없습니다. 환불처리를 사용하세요 — 실제 결제 취소(환불)까지 함께 진행됩니다.';
    end if;
  end if;

  update public.orders
  set
    status = p_status,
    -- 레거시 pending→paid 수동 전이만 payment_status를 만진다.
    -- (cancelled 전이는 위 가드로 미결제 주문만 도달 — payment_status는 그대로 둔다)
    payment_status = case
      when p_status = 'paid' then 'paid'
      else payment_status
    end,
    tracking_number = coalesce(p_tracking_number, tracking_number),
    tracking_carrier = coalesce(p_tracking_carrier, tracking_carrier),
    confirmed_at = case when p_status = 'confirmed' then now() else confirmed_at end,
    auto_confirm_at = case when p_status = 'delivered' then now() + interval '7 days' else auto_confirm_at end,
    updated_at = now()
  where id = p_order_id;

  if p_status = 'paid' then
    -- paid 전이: books → reserved (트리거가 is_public=false 자동 set)
    update public.books
    set status = 'reserved'
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'on_sale';
  elsif p_status = 'cancelled' then
    -- cancelled 복원: status=on_sale + is_public=true 같이 set.
    -- 트리거가 product_id/title/price/condition_grade 검증하지만, 결제까지 갔던
    -- 책은 모두 만족하므로 통과.
    update public.books
    set status = 'on_sale', is_public = true
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'reserved';
  end if;

  if p_status = 'cancelled' and v_order.applied_member_coupon_id is not null then
    update public.member_coupons
    set used_at = null,
        used_order_id = null,
        status = case
          when expires_at is not null and expires_at < now() then 'expired'
          else 'available'
        end,
        updated_at = now()
    where id = v_order.applied_member_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'order_id', p_order_id, 'new_status', p_status);
end;
$$;

grant execute on function public.admin_update_order_status(bigint, text, text, text) to authenticated;

commit;

notify pgrst, 'reload schema';
