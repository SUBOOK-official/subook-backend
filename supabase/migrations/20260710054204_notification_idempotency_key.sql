-- 알림톡 발송 멱등성 키 (2026-07-10)
--
-- 문제: notification_logs에 유니크 제약이 없고 발송 전 중복 체크도 없어,
-- 어드민 버튼 더블클릭·일괄 재실행·동시 요청 시 같은 이벤트의 알림톡이 중복 발송됨.
--
-- 조치: 발송 코드(send-notification.js)가 발송 전에 pending 로그를
-- idempotency_key(타입:참조타입:참조ID:수신번호)와 함께 INSERT로 선점한다.
-- 같은 이벤트의 두 번째 시도는 아래 unique 인덱스 충돌(23505)로 걸러진다.
-- 발송 실패 시 코드가 키를 NULL로 반납해 재시도를 허용하고,
-- 명시적 재전송(allowDuplicate)은 키 없이 발송한다.

alter table public.notification_logs
  add column if not exists idempotency_key text null;

create unique index if not exists uniq_notification_logs_idempotency_key
  on public.notification_logs (idempotency_key)
  where idempotency_key is not null;
