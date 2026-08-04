-- 상품 등록 시 AI 요약 자동 생성 (2026-08-03)
--
-- 배경: AI 요약은 배치 스크립트(generate-ai-summaries.mjs) 수동 실행뿐이라
--   7/20 전체 배치 이후 등록된 62개 상품이 전부 미생성으로 쌓였음 (8/3 백필 완료).
--   재발 방지를 위해 등록 즉시 자동 생성 경로를 추가한다.
--
-- 아키텍처 (슬랙 20260720130000 · 구글시트 20260720134859 패턴과 동일):
--   products INSERT → AFTER 트리거 → pg_net(커밋 후 비동기)
--     → admin.subook.kr/api/admin/book-studio (body.mode="summary" 분기, Gemini 호출·저장)
--   * 별도 함수가 아니라 book-studio 겸용인 이유: Vercel Hobby 서버리스 함수
--     12개 상한에 이미 도달 — 13번째 함수는 배포 거부됨 (2026-08-03 실측).
--   + pg_cron 스위퍼: 30분마다 누락분(ai_summary null, 생성 3분 경과) 최대 3건 재시도
--     — 트리거 유실(엔드포인트 장애·Gemini 오류·시크릿 부재 기간)을 자가 치유.
--   * 엔드포인트는 이미 요약이 있으면 skip (멱등) — 트리거·스위퍼 중복 호출 안전.
--   * 인증: Vault 시크릿 `ai_summary_webhook_token`을 요청 body.token으로 전달
--     (값 = service role key. 엔드포인트가 자기 env와 비교 검증 — gsheet token 방식).
--     등록:  select vault.create_secret('<service_role_key>',
--                                       'ai_summary_webhook_token', 'AI 요약 자동생성 웹훅 토큰');
--     미등록이면 트리거·스위퍼는 조용히 no-op (상품 등록은 정상 동작).
--   * 실패는 전부 삼켜 상품 등록을 절대 막지 않는다.
--
-- ⚠ 운영 주의 (gsheet와 동일): 스크립트로 products를 대량 INSERT하면 건당 Gemini
--   호출(≈₩55)이 그대로 발사된다. 대량 작업 전 Vault의 ai_summary_webhook_token을
--   잠시 지웠다가 재등록할 것. (지운 동안 쌓인 누락분은 스위퍼가 3건/30분으로 서서히
--   메우거나, GitHub Actions 배치로 한 번에 처리.)
--
-- 변경 요약 (비파괴): 함수 3종 + AFTER INSERT 트리거 1건 + pg_cron 잡 1건.
-- 롤백: drop trigger trg_products_auto_ai_summary on public.products;
--        select cron.unschedule('subook-ai-summary-sweep');

begin;

create extension if not exists pg_net;

-- ── 단건 생성 요청 발사 (pg_net) ────────────────────────────────────
create or replace function public.request_ai_summary_generation(p_product_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  select decrypted_secret into v_token
  from vault.decrypted_secrets
  where name = 'ai_summary_webhook_token'
  limit 1;

  if v_token is null or btrim(v_token) = '' then
    return; -- 시크릿 미등록 = 자동 생성 비활성 (조용히 no-op)
  end if;

  -- 타임아웃은 응답 대기 한도일 뿐 — 초과해도 서버리스 쪽 생성·저장은 계속 진행됨
  -- (gsheet 20260721060524와 동일 근거)
  perform net.http_post(
    url := 'https://admin.subook.kr/api/admin/book-studio',
    body := jsonb_build_object('mode', 'summary', 'token', v_token, 'productId', p_product_id),
    timeout_milliseconds := 25000
  );
exception when others then
  null; -- 요약 생성 실패가 본 흐름(상품 등록·스위퍼)을 막으면 안 됨
end;
$$;

-- ── products INSERT 트리거 ─────────────────────────────────────────
create or replace function public.trg_request_ai_summary_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.request_ai_summary_generation(new.id);
  return new;
exception when others then
  return new;
end;
$$;

drop trigger if exists trg_products_auto_ai_summary on public.products;
create trigger trg_products_auto_ai_summary
  after insert on public.products
  for each row
  when (new.ai_summary is null)
  execute function public.trg_request_ai_summary_on_insert();

-- ── 누락분 스위퍼 (pg_cron, 30분마다 최대 3건) ──────────────────────
-- 생성 3분 경과 조건: 방금 INSERT돼 트리거 경로가 아직 처리 중인 행과의 경합 방지.
create or replace function public.sweep_missing_ai_summaries(p_limit integer default 3)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_count integer := 0;
begin
  for v_id in
    select id
    from public.products
    where ai_summary is null
      and created_at < now() - interval '3 minutes'
    order by created_at asc
    limit greatest(coalesce(p_limit, 3), 0)
  loop
    perform public.request_ai_summary_generation(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
exception when others then
  return v_count;
end;
$$;

do $$
begin
  begin
    perform cron.unschedule('subook-ai-summary-sweep');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'subook-ai-summary-sweep',
    '*/30 * * * *',
    $job$ select public.sweep_missing_ai_summaries(); $job$
  );
end $$;

commit;
