-- notification_logs CHECK 제약 확장 (솔라피 실발송 전 필수 수정)
--
-- 문제: 원본 마이그레이션(2026041201)의 CHECK가 초기 8종 타입만 허용하는데,
-- 발송 코드(admin-web api/admin/send-notification.js)는 이후 추가된
-- restock(재입고)·refund_completed(환불) 타입과 ref_type='product'(재입고)를 보낸다.
-- → 해당 타입 발송 시 알림톡은 나가지만 로그 INSERT가 CHECK 위반으로 실패
--   (코드는 console.error 후 진행이라 조용히 로그 유실).
--
-- 조치: 제약을 drop 후 현행 10종 + ref_type 5종으로 재생성 (동일 마이그레이션 내 재추가).

begin;

alter table public.notification_logs
  drop constraint if exists notification_logs_notification_type_check;

alter table public.notification_logs
  add constraint notification_logs_notification_type_check
  check (notification_type in (
    'pickup_accepted',    -- 수거접수 완료 (셀러)
    'arrived',            -- 입고 완료 (셀러)
    'inspection_done',    -- 검수 완료 (셀러)
    'sold',               -- 판매 완료 (셀러)
    'settlement_done',    -- 정산 완료 (셀러)
    'order_confirmed',    -- 주문 확인 (구매자)
    'shipping_started',   -- 배송 시작 (구매자)
    'delivery_done',      -- 배송 완료 (구매자)
    'restock',            -- 재입고 알림 (구매자)
    'refund_completed'    -- 환불 완료 (구매자)
  ));

alter table public.notification_logs
  drop constraint if exists notification_logs_ref_type_check;

alter table public.notification_logs
  add constraint notification_logs_ref_type_check
  check (ref_type is null or ref_type in (
    'pickup_request',
    'shipment',
    'order',
    'settlement',
    'product'             -- 재입고 알림의 연관 엔티티
  ));

commit;
