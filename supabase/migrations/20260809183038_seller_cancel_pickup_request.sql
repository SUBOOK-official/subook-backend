-- 셀러 셀프 수거 취소 — CJ 접수 전(pending)에만 허용
--
-- 배경(2026-08-09): 장난/시험 수거신청이 접수 큐에 남아 운영자가 실수로 CJ 접수하면
--   기사 헛걸음이 된다. 신청자가 접수 전에 스스로 정리할 수 있는 경로를 만든다.
--
-- 정책:
--   - 본인(user_id) 소유 + status='pending'만 취소 가능.
--   - CJ 접수 후(pickup_scheduled~)는 기사 배차가 잡혀 있어 셀러 직접 취소 불가 —
--     admin 취소(CJ CnclBook 연동, cj-pickup.js action=cancel)만 가능하다는 안내를 띄운다.
--   - status 외에 운송장 흔적(tracking_number, box_waybills)도 이중 확인(부분 접수 방어).
--   - 차단 회원도 자기 신청 취소는 허용 — 취소는 운영 부담을 줄이는 방향이라
--     assert_member_not_blocked를 의도적으로 태우지 않는다.
--   - 이미 cancelled면 성공으로 응답(멱등).

create or replace function public.cancel_my_pickup_request(
  p_request_id bigint,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_row record;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select id, status, request_number, tracking_number, box_waybills
    into v_row
    from public.pickup_requests
    where id = p_request_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception '수거 신청을 찾을 수 없습니다.';
  end if;

  if v_row.status = 'cancelled' then
    return jsonb_build_object(
      'success', true,
      'request_number', v_row.request_number,
      'already_cancelled', true
    );
  end if;

  if v_row.status <> 'pending'
     or v_row.tracking_number is not null
     or jsonb_array_length(coalesce(v_row.box_waybills, '[]'::jsonb)) > 0 then
    raise exception '이미 수거 접수가 진행되어 직접 취소할 수 없습니다. 카카오톡 채널로 문의해 주세요.';
  end if;

  update public.pickup_requests
  set status = 'cancelled',
      cancel_reason = coalesce(nullif(btrim(p_reason), ''), '셀러 직접 취소'),
      updated_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'success', true,
    'request_number', v_row.request_number,
    'already_cancelled', false
  );
end;
$$;

grant execute on function public.cancel_my_pickup_request(bigint, text) to authenticated;

notify pgrst, 'reload schema';
