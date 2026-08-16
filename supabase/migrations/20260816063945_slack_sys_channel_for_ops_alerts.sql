-- 시스템 경보 전용 슬랙 채널 분리 (2026-08-16)
--
-- 배경: notify_ops_slack(결제 CRITICAL·자동화 헬스 리포트)이 주문/수거 알림과 같은
--   Vault 시크릿(slack_ops_webhook_url)을 쓰고 있어 팀 공유 채널로 시스템 경보가
--   섞여 들어감 → 운영자 전용 프라이빗 채널로 분리 요청.
--
-- 설계:
--   * 시스템 경보용 신규 시크릿 `slack_sys_webhook_url`을 우선 사용, 미등록이면
--     기존 `slack_ops_webhook_url`로 폴백 — 시크릿 등록 전에도 경보 공백 없음.
--   * 주문/수거 알림 트리거(notify_slack_new_order/new_pickup)는 손대지 않음 —
--     기존 팀 채널 그대로.
--   * 시크릿 등록(운영자가 Supabase SQL Editor에서 1회 실행):
--       select vault.create_secret('https://hooks.slack.com/services/…',
--                                  'slack_sys_webhook_url', '시스템 경보 전용(프라이빗)');
--
-- 비파괴: notify_ops_slack 재정의만. 권한(service_role 전용)은 기존 grant 승계.

begin;

create or replace function public.notify_ops_slack(p_text text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  if p_text is null or btrim(p_text) = '' then
    return;
  end if;

  -- 시스템 경보 전용 채널 우선, 미등록이면 팀 운영 채널 폴백
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_sys_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    select decrypted_secret into v_url
    from vault.decrypted_secrets
    where name = 'slack_ops_webhook_url'
    limit 1;
  end if;

  if v_url is null or btrim(v_url) = '' then
    return;
  end if;

  -- 슬랙 text 상한(4000자) 보호
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('text', left(p_text, 3500))
  );
exception when others then
  -- 경보 실패가 호출부(결제 확정 등)를 절대 막으면 안 됨
  null;
end;
$$;

commit;
