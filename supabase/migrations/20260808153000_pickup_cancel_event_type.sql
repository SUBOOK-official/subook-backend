-- pickup_logistics_events.event_type에 'pickup_cancel' 허용.
--
-- admin 수거 취소가 CJ CnclBook(예약취소)을 함께 호출하도록 개편되면서
-- 박스별 취소 시도(성공/거부)를 이벤트로 남긴다. 기존 CHECK 제약이
-- ('pickup_register','tracking_lookup')만 허용해 확장.
--
-- 비파괴: 동일 제약을 허용값만 넓혀 재생성 (기존 행은 모두 통과).

begin;

alter table public.pickup_logistics_events
  drop constraint if exists pickup_logistics_events_event_type_check;

alter table public.pickup_logistics_events
  add constraint pickup_logistics_events_event_type_check
  check (event_type in ('pickup_register', 'tracking_lookup', 'pickup_cancel'));

commit;
