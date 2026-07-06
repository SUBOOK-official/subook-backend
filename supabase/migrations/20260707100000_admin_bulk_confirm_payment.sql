-- 무통장 입금확인 일괄 처리 RPC.
--
-- 운영 피드백(2026-07-06): 주문마다 모달에서 금액·입금자명을 입력하는 입금확인 절차가
-- 번거로움. 체크박스로 선택한 무통장 입금대기(pending) 주문을 별도 입력 없이 한 번에
-- 처리하는 상단 버튼이 필요 (기존 '일괄 주문취소' 버튼 자리 대체).
--
-- admin_confirm_payment(p_order_id, null)은 금액 검증을 skip하고
--   pending → preparing 전이 + payment_status='paid' + 주문 책 on_sale→reserved
-- 를 그대로 수행한다 (20260702150000 참고). 이 RPC는 그 함수를 주문별로 loop 호출하되
-- 개별 실패(동일 책 충돌 등)가 전체를 막지 않도록 subtransaction으로 감싸고,
-- 성공/제외/실패 내역을 반환한다. 알림톡 발송은 단건 흐름과 동일하게 클라이언트 담당.

begin;

create or replace function public.admin_bulk_confirm_payment(p_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_order record;
  v_success_ids bigint[] := '{}';
  v_skipped jsonb := '[]'::jsonb;
  v_failures jsonb := '[]'::jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_ids is null or coalesce(array_length(p_ids, 1), 0) = 0 then
    raise exception '선택된 주문이 없습니다.';
  end if;

  foreach v_id in array p_ids loop
    select id, order_number, status, payment_method
    into v_order
    from public.orders
    where id = v_id;

    if not found then
      v_failures := v_failures || jsonb_build_object(
        'order_id', v_id,
        'error', '주문을 찾을 수 없습니다.'
      );
      continue;
    end if;

    -- 무통장(bank_transfer) + 입금대기(pending) 주문만 대상. 그 외는 skip으로 분류.
    -- (PG 주문은 결제 승인 시 자동 전이되므로 수동 입금확인 대상이 아님)
    if v_order.payment_method <> 'bank_transfer' or v_order.status <> 'pending' then
      v_skipped := v_skipped || jsonb_build_object(
        'order_id', v_id,
        'order_number', v_order.order_number,
        'reason', case
          when v_order.payment_method <> 'bank_transfer' then 'PG 결제 주문'
          else '입금대기 상태 아님(' || v_order.status || ')'
        end
      );
      continue;
    end if;

    begin
      perform public.admin_confirm_payment(v_id, null);
      v_success_ids := array_append(v_success_ids, v_id);
    exception when others then
      v_failures := v_failures || jsonb_build_object(
        'order_id', v_id,
        'order_number', v_order.order_number,
        'error', sqlerrm
      );
    end;
  end loop;

  return jsonb_build_object(
    'success', true,
    'success_count', coalesce(array_length(v_success_ids, 1), 0),
    'success_ids', to_jsonb(v_success_ids),
    'skipped_count', jsonb_array_length(v_skipped),
    'skipped', v_skipped,
    'fail_count', jsonb_array_length(v_failures),
    'failures', v_failures
  );
end;
$$;

grant execute on function public.admin_bulk_confirm_payment(bigint[]) to authenticated;

comment on function public.admin_bulk_confirm_payment(bigint[]) is
  '선택한 무통장 pending 주문 일괄 입금확인 — admin_confirm_payment(id, null) loop, 금액 검증 없음 (2026-07-06 운영 피드백)';

commit;
