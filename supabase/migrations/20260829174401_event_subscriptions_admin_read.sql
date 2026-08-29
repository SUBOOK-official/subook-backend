-- 이벤트 알림 신청 어드민 조회 (2026-08-30)
--
-- admin-web /admin/event-subscriptions 화면이 명단·추이를 직접 조회한다.
-- notification_logs_admin_all과 동일 패턴: is_admin_user() 기반 SELECT 정책만 추가.
-- (INSERT는 계속 submit_event_subscription RPC 전용, anon/일반 회원 직접 접근은 여전히 차단)
--
-- 비파괴: CREATE POLICY only.

begin;

drop policy if exists event_subscriptions_admin_read on public.event_subscriptions;
create policy event_subscriptions_admin_read
  on public.event_subscriptions
  for select
  to authenticated
  using (public.is_admin_user());

commit;
