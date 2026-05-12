-- 묶음 4: 미입금 24h 자동 취소
--
-- 사용자에게는 "24시간 이내 미입금 시 자동 취소" 안내. 실제로 그 cron이 없었음.
-- pending 상태로 24시간 경과한 주문을 cancelled로 전이 + 쿠폰 복구 + 알림 로그.

create or replace function public.expire_unpaid_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_count integer := 0;
  v_coupon_restored integer := 0;
  v_order record;
begin
  -- pending 상태로 24시간 이상 지난 주문 일괄 처리
  for v_order in
    select id, applied_member_coupon_id
    from public.orders
    where status = 'pending'
      and payment_status = 'pending'
      and created_at < now() - interval '24 hours'
  loop
    update public.orders
    set
      status = 'cancelled',
      payment_status = 'refunded',  -- 결제 없으니 사실상 noop이지만 정합성
      updated_at = now()
    where id = v_order.id;

    -- 사용된 쿠폰이 있었으면 복구 (member_coupons trigger가 status='used'로 만든 걸 되돌림)
    if v_order.applied_member_coupon_id is not null then
      update public.member_coupons
      set
        status = 'available',
        used_at = null,
        used_order_id = null,
        updated_at = now()
      where id = v_order.applied_member_coupon_id
        and status = 'used';
      get diagnostics v_coupon_restored = row_count;
    end if;

    v_expired_count := v_expired_count + 1;
  end loop;

  return jsonb_build_object(
    'expired_count', v_expired_count,
    'coupons_restored', v_coupon_restored
  );
end;
$$;

grant execute on function public.expire_unpaid_orders() to service_role;
