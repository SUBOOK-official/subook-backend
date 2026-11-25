-- CSP(콘텐츠 보안 정책) 위반 보고를 모은다.
--
-- 브라우저가 정책 위반을 /api/csp-report(public-web 서버리스)로 보내면 그 함수가 이 RPC를
-- service_role로 호출한다. 관찰 모드(Report-Only)에서는 "차단으로 바꾸면 무엇이 막히는지"를
-- 미리 보고, 차단 모드로 바꾼 뒤에는 새로 깨지는 곳을 잡는 용도다.
--
-- 공개 엔드포인트라 누구나 보낼 수 있으므로 원문을 쌓지 않는다. 같은
-- (앱·모드·지시어·막힌 출처)는 한 행에 횟수만 올리고 전체 행 수에 상한을 둔다.
-- IP·쿼리 문자열·쿠키는 저장하지 않는다(경로와 출처만).
--
-- 롤백:
--   drop function if exists public.record_csp_violation(jsonb);
--   drop table if exists public.csp_violation_reports;

begin;

create table public.csp_violation_reports (
  id bigint generated always as identity primary key,
  app text not null,
  disposition text not null,
  directive text not null,
  blocked text not null,
  blocked_url text not null default '',
  document_path text not null default '',
  source_file text not null default '',
  sample text not null default '',
  user_agent text not null default '',
  hits integer not null default 1,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  constraint csp_violation_reports_app_check check (app in ('public', 'admin')),
  constraint csp_violation_reports_disposition_check check (disposition in ('enforce', 'report')),
  constraint csp_violation_reports_key unique (app, disposition, directive, blocked)
);

comment on table public.csp_violation_reports is
  'CSP 위반 보고 집계. disposition=report는 관찰 모드(실제로는 안 막힘), enforce는 실제로 막힌 것.';

alter table public.csp_violation_reports enable row level security;
revoke all on table public.csp_violation_reports from public, anon, authenticated;
grant select, insert, update, delete on table public.csp_violation_reports to service_role;

create or replace function public.record_csp_violation(p_report jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app text;
  v_disposition text;
  v_directive text;
  v_blocked text;
  v_blocked_url text;
  v_document_path text;
  v_source_file text;
  v_sample text;
  v_user_agent text;
  v_total integer;
begin
  if p_report is null or jsonb_typeof(p_report) <> 'object' then
    return false;
  end if;

  v_app := coalesce(p_report ->> 'app', '');
  v_disposition := coalesce(p_report ->> 'disposition', '');
  v_directive := btrim(coalesce(p_report ->> 'directive', ''));
  v_blocked := left(btrim(coalesce(p_report ->> 'blocked', '')), 200);
  v_blocked_url := left(coalesce(p_report ->> 'blockedUrl', ''), 300);
  v_document_path := left(coalesce(p_report ->> 'documentPath', ''), 200);
  v_source_file := left(coalesce(p_report ->> 'sourceFile', ''), 300);
  v_sample := left(coalesce(p_report ->> 'sample', ''), 120);
  v_user_agent := left(coalesce(p_report ->> 'userAgent', ''), 200);

  if v_app not in ('public', 'admin')
    or v_disposition not in ('enforce', 'report')
    or v_directive !~ '^[a-z][a-z-]{2,39}$'
    or v_blocked = '' then
    return false;
  end if;

  -- 이미 본 조합은 횟수만 올리고 최근 사례로 갈아 끼운다.
  update public.csp_violation_reports
  set hits = least(hits + 1, 2000000000),
      last_seen_at = now(),
      blocked_url = v_blocked_url,
      document_path = v_document_path,
      source_file = v_source_file,
      sample = v_sample,
      user_agent = v_user_agent
  where app = v_app
    and disposition = v_disposition
    and directive = v_directive
    and blocked = v_blocked;

  if found then
    return true;
  end if;

  -- 새 조합만 상한을 본다. 가짜 출처를 무한히 지어내 보내도 행 수는 여기서 멈춘다.
  delete from public.csp_violation_reports
  where last_seen_at < now() - interval '90 days';

  select count(*)::integer into v_total from public.csp_violation_reports;
  if v_total >= 500 then
    return false;
  end if;

  insert into public.csp_violation_reports (
    app, disposition, directive, blocked, blocked_url, document_path, source_file, sample, user_agent
  )
  values (
    v_app, v_disposition, v_directive, v_blocked, v_blocked_url, v_document_path, v_source_file, v_sample, v_user_agent
  )
  on conflict on constraint csp_violation_reports_key do update
    set hits = least(public.csp_violation_reports.hits + 1, 2000000000),
        last_seen_at = now();

  return true;
end;
$$;

-- Supabase 기본 권한은 새 함수에 anon·authenticated 실행 권한을 역할별로 따로 준다 — 셋 다 회수.
revoke execute on function public.record_csp_violation(jsonb) from public, anon, authenticated;
grant execute on function public.record_csp_violation(jsonb) to service_role;

commit;
