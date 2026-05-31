-- 이미 셀러에게 송금 완료(settlements.status='completed')된 정산이 있는 주문을
-- admin_refund_order로 환불하면 그 돈은 회수가 사실상 불가능 = 회사 손실.
-- 운영자가 실수로 손실을 내지 않도록, 명시적 확인(p_acknowledge_recovery=true) 없이는 차단한다.
--
-- 프론트(AdminOrdersPage)는 먼저 p_acknowledge_recovery=false로 호출 →
-- 'RECOVERY_REQUIRED_ACK' 예외를 받으면 "회수 불가 = 손실" 확인 모달을 띄우고,
-- 운영자가 손실을 감수하면 p_acknowledge_recovery=true로 재호출한다.
--
-- 시그니처가 (bigint, text) → (bigint, text, boolean)으로 바뀌므로 기존 함수를 drop 후 재생성.
-- (DROP FUNCTION은 데이터 비파괴. 함수 본문은 20260525200000 버전과 동일하며 가드만 추가했다.)

begin;

drop function if exists public.admin_refund_order(bigint, text);

create or replace function public.admin_refund_order(
  p_order_id bigint,
  p_reason text default null,
  p_acknowledge_recovery boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_now timestamptz := now();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_cancelled_settlements integer := 0;
  v_recovery_settlements integer := 0;
  v_restored_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status in ('cancelled', 'refunded') then
    raise exception '이미 취소/환불된 주문입니다. (현재: %)', v_order.status;
  end if;

  -- ⚠ 이미 셀러에게 송금 완료(completed)된 정산이 있으면 환불 시 회수가 사실상 불가능 = 회사 손실.
  --    운영자가 명시적으로 손실을 감수(p_acknowledge_recovery=true)하지 않으면 차단한다.
  if not coalesce(p_acknowledge_recovery, false) then
    if exists (
      select 1 from public.settlements
      where order_id = p_order_id and status = 'completed'
    ) then
      raise exception 'RECOVERY_REQUIRED_ACK: 이미 셀러에게 정산금이 송금 완료된 주문입니다. 환불 시 회수가 불가능하여 회사 손실로 처리됩니다.';
    end if;
  end if;

  update public.orders
  set
    status = 'refunded',
    payment_status = case when payment_status = 'paid' then 'refunded' else payment_status end,
    refunded_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where id = p_order_id;

  update public.settlements
  set
    status = 'cancelled',
    cancelled_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where order_id = p_order_id
    and status in ('pending', 'approved');
  get diagnostics v_cancelled_settlements = row_count;

  update public.settlements
  set
    status = 'recovery_required',
    recovery_required_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where order_id = p_order_id
    and status = 'completed';
  get diagnostics v_recovery_settlements = row_count;

  if v_order.applied_member_coupon_id is not null then
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

  -- reserved 책을 on_sale + is_public=true로 같이 복원 (settled 책은 정산 처리됐으므로 제외)
  update public.books
  set status = 'on_sale', is_public = true
  where id in (
    select oi.book_id from public.order_items oi where oi.order_id = p_order_id
  )
  and status = 'reserved';
  get diagnostics v_restored_books = row_count;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'cancelled_settlements', v_cancelled_settlements,
    'recovery_required_settlements', v_recovery_settlements,
    'restored_books', v_restored_books,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

grant execute on function public.admin_refund_order(bigint, text, boolean) to authenticated;

commit;
