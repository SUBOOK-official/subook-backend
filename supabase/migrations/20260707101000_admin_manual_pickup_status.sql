-- 수거 요청 수동 상태 전환 RPC.
--
-- 운영 피드백(2026-07-06): CJ 운영 계약 전이라 CJ_CUST_ID가 없어 'CJ 수거 접수' 버튼이
-- 항상 실패 → 수거 요청이 pending에서 영영 못 벗어나고, 판매신청 프로세스 전체 검증이
-- 막혀 있음. CJ 접수 없이도 어드민이 자체적으로 상태(특히 '검수중')를 바꿀 수 있어야 함.
--
-- 현재 pickup_requests.status의 쓰기 경로는 3개뿐:
--   · cj-pickup.js  → pickup_scheduled
--   · cj-tracking.js → 최대 arrived
--   · admin_bulk_cancel_pickup_requests → cancelled
-- 즉 inspecting/inspected/completed는 도달 불가능한 상태였다. 이 RPC가 그 간극을 메운다.
--
-- 설계:
--   · 대상 상태: cancelled를 제외한 7개 (취소는 사유 입력이 있는 기존 RPC 전용).
--   · cancelled 상태에서는 전환 불가 (취소 철회는 별도 운영 판단 필요).
--   · 전·후진 모두 허용 — 운영자 실수 복구용. 셀러 마이페이지 스테퍼는 status 기반이라
--     어떤 값이든 즉시 올바르게 렌더링됨 (publicMypageUtils의 pickupStatusToShipmentStatus).
--   · 알림톡은 발송하지 않음 (CJ 미연동 기간의 수동 운영 — 셀러 안내는 운영자 재량).

begin;

create or replace function public.admin_update_pickup_status(
  p_id bigint,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request record;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_status is null or p_status not in
    ('pending', 'pickup_scheduled', 'picking_up', 'arrived', 'inspecting', 'inspected', 'completed')
  then
    raise exception '허용되지 않는 상태입니다: %. (취소는 일괄 취소 기능을 사용하세요)', coalesce(p_status, 'null');
  end if;

  select id, request_number, status
  into v_request
  from public.pickup_requests
  where id = p_id
  for update;

  if not found then
    raise exception '수거 요청을 찾을 수 없습니다. (id: %)', p_id;
  end if;

  if v_request.status = 'cancelled' then
    raise exception '취소된 수거 요청(%)은 상태를 변경할 수 없습니다.', v_request.request_number;
  end if;

  if v_request.status = p_status then
    return jsonb_build_object(
      'success', true,
      'id', v_request.id,
      'request_number', v_request.request_number,
      'old_status', v_request.status,
      'new_status', p_status,
      'changed', false
    );
  end if;

  update public.pickup_requests
  set status = p_status,
      updated_at = now()
  where id = p_id;

  return jsonb_build_object(
    'success', true,
    'id', v_request.id,
    'request_number', v_request.request_number,
    'old_status', v_request.status,
    'new_status', p_status,
    'changed', true
  );
end;
$$;

grant execute on function public.admin_update_pickup_status(bigint, text) to authenticated;

comment on function public.admin_update_pickup_status(bigint, text) is
  '수거 요청 수동 상태 전환 (CJ 미연동 기간 운영용, cancelled 제외 7개 상태) — 2026-07-06 운영 피드백';

commit;
