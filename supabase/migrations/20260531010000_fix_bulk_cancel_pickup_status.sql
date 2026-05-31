-- 수거 요청 일괄취소가 항상 0건(사실상 pending만) 처리되던 버그 수정 + 취소 사유 저장.
--
-- 버그: admin_bulk_cancel_pickup_requests가 존재하지 않는 상태값 'pickup_assigned'로 걸러,
--       실제로는 'pending'만 취소되고 'pickup_scheduled'(CJ 접수됐으나 미수거) 등은 무시됐다.
--       (pickup_requests.status enum: pending/pickup_scheduled/picking_up/arrived/
--        inspecting/inspected/completed/cancelled — 'pickup_assigned'는 없음)
-- 변경: 'pickup_assigned' → 'pickup_scheduled'. 즉 아직 수거 전인 pending + pickup_scheduled를 취소.
--       또한 강제 입력받던 취소 사유(p_reason)를 cancel_reason 컬럼에 저장
--       (기존엔 `perform p_reason`으로 버려져 입력이 무의미 + 셀러 문의 시 근거 없음).
--
-- 비파괴: ADD COLUMN IF NOT EXISTS(nullable) + CREATE OR REPLACE FUNCTION(동일 시그니처).

begin;

alter table public.pickup_requests
  add column if not exists cancel_reason text null;

create or replace function public.admin_bulk_cancel_pickup_requests(
  p_ids bigint[],
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  update public.pickup_requests
  set
    status = 'cancelled',
    cancel_reason = nullif(btrim(coalesce(p_reason, '')), ''),
    updated_at = now()
  where id = any(p_ids)
    and status in ('pending', 'pickup_scheduled');

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'cancelled_count', v_updated_count);
end;
$$;

grant execute on function public.admin_bulk_cancel_pickup_requests(bigint[], text) to authenticated;

commit;
