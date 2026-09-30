-- 관리자 외부 업무의 초안과 변경 이력. 외부 호출은 서버 API에서만 수행한다.
-- 롤백: API를 이전 배포로 되돌린다. 운영 변경 이력은 삭제하지 않는다.
begin;
create table public.admin_external_drafts (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('meta')),
  kind text not null check (kind in ('campaign','adset','ad','creative')),
  title text not null check (length(title) between 1 and 200),
  payload jsonb not null check (jsonb_typeof(payload)='object' and octet_length(payload::text)<=65536),
  version integer not null default 1 check (version > 0),
  created_by uuid not null references auth.users(id),
  updated_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create table public.admin_external_actions (
  id uuid primary key,
  provider text not null check (provider in ('meta')),
  account_id text not null,
  actor_id uuid not null references auth.users(id),
  actor_name text,
  action text not null check (action in ('create','update','status','copy','image','video')),
  kind text not null check (kind in ('campaign','adset','ad','creative')),
  object_id text,
  request_hash text not null,
  expected_version text,
  payload jsonb,
  review jsonb not null,
  state text not null default 'prepared' check (state in ('prepared','executing','succeeded','failed','unknown','expired')),
  result jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '10 minutes',
  finished_at timestamptz
);
create index admin_external_actions_recent on public.admin_external_actions(created_at desc);
create index admin_external_actions_actor_recent on public.admin_external_actions(actor_id,created_at desc);
create index admin_external_drafts_recent on public.admin_external_drafts(updated_at desc) where archived_at is null;
alter table public.admin_external_drafts enable row level security;
alter table public.admin_external_actions enable row level security;
revoke all on public.admin_external_drafts,public.admin_external_actions from public,anon,authenticated;
grant select,insert,update on public.admin_external_drafts,public.admin_external_actions to service_role;
comment on table public.admin_external_actions is '관리자 API 전용. 실행 전 변경 내용 검토, 동시 변경 방지, 결과 불명 요청 재실행 방지. 인증 토큰 저장 금지.';
create unique index admin_external_actions_one_writer
  on public.admin_external_actions(provider,account_id,object_id)
  where state = 'executing' and object_id is not null;
commit;
