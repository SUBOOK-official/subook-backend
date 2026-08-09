-- 등록 = 검수 시작 (2026-08-09)
--
-- 배경: 어드민 "검수중으로 변경" 버튼은 원래 입고 알림톡(정확한 권수 필요) 발사 장치라
-- "등록 → 검수중 전환" 순서가 강제돼 있었다. 알림톡 템플릿 v2 전환으로 입고 알림이
-- 폐지되면서 버튼은 의례적 클릭만 남았고, 실제로 클릭을 깜빡해 scheduled에 멈춘
-- 등급 완료 작업분 3건(#54/#55/#56)이 확인됨. 등록 위저드의 실작업(책 확인·등급·가격)이
-- 곧 검수이므로 상태 기계를 현실에 맞춘다. 프론트의 수동 버튼은 제거(frontend 커밋 참조).
--
-- 1) books INSERT 트리거: shipment에 첫 책이 등록되는 순간 scheduled → inspecting.
--    (경로 무관: admin_register_customer_inventory RPC든 직접 insert든 동일 동작.
--     대량 백필 INSERT는 scheduled 가드로 사실상 no-op — 검수 지난 shipment는 불변)
-- 2) shipments 상태 트리거: inspecting/inspected 전환 시 브리지된 pickup_requests.status를
--    전방향으로만 동기화. 이전엔 shipment와 수거요청 상태를 어드민이 이중 수동 관리라
--    검수완료 알림톡이 나가도 셀러 마이페이지 스테퍼는 '입고'에 멈출 수 있었다.
--    (cancelled/completed 불가침, 후진 없음, 알림톡 발송 없음.
--     수동 복구용 admin_update_pickup_status의 전·후진 허용은 그대로 유효)
-- 3) 백필: scheduled인데 책이 이미 등록된 shipment를 inspecting으로 전환(현재 3건).
--    2) 트리거가 함께 발화해 브리지된 수거요청도 검수중으로 정렬된다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 책 등록 → 검수중 자동 전환
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.auto_inspecting_on_book_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.shipments
  set status = 'inspecting'
  where id = new.shipment_id
    and status = 'scheduled';
  return new;
end;
$$;

comment on function public.auto_inspecting_on_book_insert() is
  '책이 등록되는 순간 소속 shipment를 scheduled → inspecting 자동 전환 (등록=검수 시작, 2026-08-09)';

drop trigger if exists trg_books_auto_inspecting on public.books;
create trigger trg_books_auto_inspecting
  after insert on public.books
  for each row
  when (new.shipment_id is not null)
  execute function public.auto_inspecting_on_book_insert();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) shipment 검수 상태 → 브리지된 수거요청 상태 전방향 동기화
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sync_pickup_status_from_shipment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'inspecting' then
    update public.pickup_requests
    set status = 'inspecting', updated_at = now()
    where id = new.pickup_request_id
      and status in ('pending', 'pickup_scheduled', 'picking_up', 'arrived');
  elsif new.status = 'inspected' then
    update public.pickup_requests
    set status = 'inspected', updated_at = now()
    where id = new.pickup_request_id
      and status in ('pending', 'pickup_scheduled', 'picking_up', 'arrived', 'inspecting');
  end if;
  return new;
end;
$$;

comment on function public.sync_pickup_status_from_shipment() is
  'shipment 검수 상태(inspecting/inspected)를 브리지된 pickup_requests에 전방향 동기화 — 셀러 스테퍼 정합 (2026-08-09)';

drop trigger if exists trg_shipments_sync_pickup_status on public.shipments;
create trigger trg_shipments_sync_pickup_status
  after update of status on public.shipments
  for each row
  when (new.pickup_request_id is not null and new.status is distinct from old.status)
  execute function public.sync_pickup_status_from_shipment();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 백필 — 등록은 끝났는데 scheduled에 멈춘 작업분을 새 규칙에 맞춤 (2026-08-09 기준 3건)
-- ─────────────────────────────────────────────────────────────────────────────
update public.shipments s
set status = 'inspecting'
where s.status = 'scheduled'
  and exists (select 1 from public.books b where b.shipment_id = s.id);

commit;
