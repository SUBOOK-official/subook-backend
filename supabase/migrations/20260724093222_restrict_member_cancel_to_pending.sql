-- 구매자 셀프 취소를 입금 확인 전(pending)으로 제한 (2026-07-24)
--
-- 문제: 기존엔 pending/paid(레거시)/preparing에서 셀프 취소 허용 — 어드민이 무통장
--       입금을 확인(pending→preparing)한 뒤에도 구매자가 혼자 취소할 수 있었다.
--       실입금이 이미 들어온 상태라 환불 이체 없이 주문만 cancelled가 되고,
--       paid 케이스는 payment_status를 실제 환불 없이 refunded로 뒤집는 부작용까지.
-- 정책: 직접 취소 = pending(입금대기)에서만. 입금 확인 후 취소·환불은 고객센터(카카오톡
--       채널) 접수 → 운영자가 admin 환불 흐름(admin_refund_order, 환불계좌 수집분)으로 처리.
--       배송중(shipping) 이후 차단은 기존과 동일.
-- 유지: assert_member_not_blocked(회원 차단 가드 — 재정의 시 유지 필수), 쿠폰 자동 복구,
--       취소 시 책 릴리스는 trg_release_books_on_order_cancel 트리거가 담당(변경 없음).

create or replace function public.cancel_member_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_order record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  select * into v_order from public.orders where id = p_order_id and user_id = v_user_id;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status <> 'pending' then
    raise exception '입금 확인 전(입금대기) 주문만 직접 취소할 수 있습니다. 입금 확인 이후의 취소·환불은 카카오톡 채널로 문의해 주세요. (현재: %)', v_order.status;
  end if;

  update public.orders
  set
    status = 'cancelled',
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  -- 쿠폰 자동 복구
  if v_order.applied_member_coupon_id is not null then
    update public.member_coupons
    set used_at = null,
        used_order_id = null,
        status = case
          when expires_at is not null and expires_at < now() then 'expired'
          else 'available'
        end
    where id = v_order.applied_member_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$function$;
