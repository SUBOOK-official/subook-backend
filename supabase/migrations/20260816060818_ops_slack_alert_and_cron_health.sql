-- 운영 경보 인프라 2종 (2026-08-16, P1 감사 후속)
--
-- 배경:
--   1) 결제 CRITICAL(나이스페이 승인 후 DB 확정·자동취소 모두 실패 = 고객 돈이 묶인 상태)이
--      서버리스 console.error에만 남아 고객 문의 전에는 인지 불가.
--   2) pg_cron 잡 4종이 죽거나 미등록돼도 무음 (8/1 pg_cron 미설치 사고, 8/13 파기 크론
--      미등록 발견 — 모두 같은 계열). gsheet 아웃박스 failed도 화면 없이 방치.
--
-- 설계:
--   * notify_ops_slack(p_text): 서버리스가 service_role로 호출하는 슬랙 발송 단일 창구.
--     기존 주문/수거 슬랙 트리거와 동일 패턴 — Vault `slack_ops_webhook_url` + pg_net.
--     예외는 전부 삼킨다 (경보 실패가 결제 흐름을 막으면 안 됨).
--   * ops_cron_health_report(): pg_cron 잡 상태 + gsheet 아웃박스 + 알림톡 실패를 점검해
--     슬랙으로 하루 1회 요약 발송. 호출은 Vercel 크론(/api/admin/ops-health)이 담당 —
--     pg_cron 자체가 죽어도 감지되는 데드맨 스위치 구조. 정상일 때도 한 줄을 보내
--     "리포트가 안 오면 그 자체가 장애 신호"가 되게 한다.
--
-- 비파괴: 신규 함수 2개 + 권한 설정만. 테이블·기존 함수 변경 없음.

begin;

-- ── 1) 슬랙 발송 단일 창구 ──────────────────────────────────────────────
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

  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

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

revoke all on function public.notify_ops_slack(text) from public;
revoke all on function public.notify_ops_slack(text) from anon;
revoke all on function public.notify_ops_slack(text) from authenticated;
grant execute on function public.notify_ops_slack(text) to service_role;

-- ── 2) 자동화 헬스 리포트 (데드맨 스위치) ────────────────────────────────
create or replace function public.ops_cron_health_report()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lines text[] := array[]::text[];
  v_warn integer := 0;
  v_last timestamptz;
  v_cnt bigint;
  v_name text;
  v_threshold integer;
  v_report text;
  -- 기대 pg_cron 잡과 "이 시간 안에 성공 실행이 없으면 경보" 임계(분).
  -- 주기 대비 넉넉히 잡아 일시 재시도·배포 공백은 무시한다.
  v_expected constant jsonb := jsonb_build_object(
    'subook-expire-unpaid-orders', 120,   -- 15분 주기
    'subook-gsheet-sync-sweep',    60,    -- 5분 주기
    'subook-ai-summary-sweep',     360,   -- 30분 주기
    'subook-privacy-purge',        2880   -- 일 1회 (KST 03:17)
  );
begin
  -- 2-1) 기대 잡: 등록 여부 + 최근 성공 실행 여부
  for v_name, v_threshold in
    select key, value::integer from jsonb_each_text(v_expected)
  loop
    if not exists (select 1 from cron.job where jobname = v_name and active) then
      v_warn := v_warn + 1;
      v_lines := v_lines || format('· %s — 크론 미등록/비활성', v_name);
      continue;
    end if;

    select max(d.end_time) into v_last
    from cron.job_run_details d
    join cron.job j on j.jobid = d.jobid
    where j.jobname = v_name
      and d.status = 'succeeded';

    if v_last is null or v_last < now() - make_interval(mins => v_threshold) then
      v_warn := v_warn + 1;
      v_lines := v_lines || format(
        '· %s — 마지막 성공 %s',
        v_name,
        coalesce(to_char(v_last at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), '기록 없음')
      );
    end if;
  end loop;

  -- 2-2) 최근 24시간 실패로 끝난 크론 실행
  select count(*) into v_cnt
  from cron.job_run_details
  where status = 'failed'
    and start_time > now() - interval '24 hours';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· pg_cron 실패 실행 %s건 (24h)', v_cnt);
  end if;

  -- 2-3) 구글시트 아웃박스: 영구 실패 + 1시간 이상 pending 정체
  select count(*) into v_cnt from gsheet_sync_outbox where status = 'failed';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· 구글시트 아웃박스 failed %s건 — admin_gsheet_resend_order로 재기록 필요', v_cnt);
  end if;

  select count(*) into v_cnt
  from gsheet_sync_outbox
  where status = 'pending'
    and created_at < now() - interval '1 hour';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· 구글시트 아웃박스 pending 정체 %s건 (1h+)', v_cnt);
  end if;

  -- 2-4) 알림톡 발송 실패 (최근 24시간)
  select count(*) into v_cnt
  from notification_logs
  where status = 'failed'
    and created_at > now() - interval '24 hours';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· 알림톡 실패 %s건 (24h) — 어드민 알림 이력에서 재발송', v_cnt);
  end if;

  -- 2-5) 슬랙 발송 (정상일 때도 한 줄 — 리포트 부재 자체가 장애 신호)
  if v_warn = 0 then
    v_report := ':white_check_mark: 수북 자동화 정상 — 크론 4종·구글시트·알림톡 이상 없음';
  else
    v_report := format(E':rotating_light: 수북 자동화 점검 필요 %s건\n%s', v_warn, array_to_string(v_lines, E'\n'));
  end if;
  perform public.notify_ops_slack(v_report);

  return jsonb_build_object('warnings', v_warn, 'lines', to_jsonb(v_lines));
end;
$$;

revoke all on function public.ops_cron_health_report() from public;
revoke all on function public.ops_cron_health_report() from anon;
revoke all on function public.ops_cron_health_report() from authenticated;
grant execute on function public.ops_cron_health_report() to service_role;

commit;
