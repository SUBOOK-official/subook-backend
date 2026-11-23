-- 수거 신청 일시 중단 스위치 (2026-11-23)
--
-- 배경: 수능 직후 수거 신청이 한꺼번에 몰려 새 신청을 잠시 받지 않는다.
--       운영자가 관리자 화면(수거·검수)에서 직접 중단·재개할 수 있어야 한다.
--
-- 구조
--   · pickup_intake_settings          한 줄짜리 설정. 직접 읽기·쓰기 권한 없음(RLS, 정책 없음).
--   · get_pickup_intake_status()      공개 조회(비로그인 포함). 중단 여부와 바뀐 시각만 돌려준다.
--   · admin_set_pickup_intake_paused  관리자만. 누가·언제 바꿨는지 설정 행에 남긴다.
--   · pickup_requests INSERT 트리거   중단 중에는 회원의 새 신청을 서버에서 거절한다.
--       신청 RPC(v1 → v2 → v3)를 재정의하지 않고 테이블에서 막는다. 어느 버전으로 들어와도,
--       나중에 새 래퍼가 생겨도 같은 자리에서 막힌다. 로그인 회원의 요청만 막고
--       서버(service_role)·DB 직접 작업은 통과한다.
--   · 이미 접수된 신청의 조회·취소·CJ 접수·검수는 그대로다(UPDATE·SELECT는 건드리지 않는다).
--
-- 초기값은 '받는 중'(is_paused = false)이다. 중단은 화면 배포를 마친 뒤 스위치로 켠다 —
-- 운영 상태를 마이그레이션에 넣지 않는다.
--
-- 롤백
--   drop trigger pickup_requests_block_while_paused on public.pickup_requests;
--   drop function public.block_pickup_request_while_paused();
--   drop function public.admin_set_pickup_intake_paused(boolean);
--   drop function public.get_pickup_intake_status();
--   drop table public.pickup_intake_settings;

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 설정 (한 줄)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.pickup_intake_settings (
  id smallint primary key default 1 check (id = 1),
  is_paused boolean not null default false,
  changed_at timestamptz not null default now(),
  changed_by uuid
);

insert into public.pickup_intake_settings (id) values (1);

comment on table public.pickup_intake_settings is
  '수거 신청 받기/중단 스위치(한 줄). 읽기는 get_pickup_intake_status(), 쓰기는 admin_set_pickup_intake_paused()로만 한다.';

alter table public.pickup_intake_settings enable row level security;
revoke all on table public.pickup_intake_settings from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 공개 조회 — 수거 신청 화면이 폼을 열지 안내를 띄울지 정한다
-- ─────────────────────────────────────────────────────────────────────────────
create function public.get_pickup_intake_status()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('paused', s.is_paused, 'changed_at', s.changed_at)
  from public.pickup_intake_settings s
  where s.id = 1;
$$;

revoke execute on function public.get_pickup_intake_status() from public, anon, authenticated;
grant execute on function public.get_pickup_intake_status() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 관리자 전환
-- ─────────────────────────────────────────────────────────────────────────────
create function public.admin_set_pickup_intake_paused(p_paused boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_paused is null then
    raise exception '중단 여부를 정해 주세요.';
  end if;

  -- 같은 값으로 다시 누르면 바뀐 시각·사람을 덮어쓰지 않는다.
  update public.pickup_intake_settings
  set is_paused = p_paused,
      changed_at = now(),
      changed_by = auth.uid()
  where id = 1
    and is_paused is distinct from p_paused;

  return public.get_pickup_intake_status();
end;
$$;

revoke execute on function public.admin_set_pickup_intake_paused(boolean) from public, anon, authenticated;
grant execute on function public.admin_set_pickup_intake_paused(boolean) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 서버 차단 — 중단 중 회원의 새 신청 거절
-- ─────────────────────────────────────────────────────────────────────────────
create function public.block_pickup_request_while_paused()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null
     and coalesce((select s.is_paused from public.pickup_intake_settings s where s.id = 1), false) then
    raise exception '지금은 수거 신청을 잠시 받지 않고 있어요. 다시 열리면 신청해 주세요.';
  end if;
  return new;
end;
$$;

revoke execute on function public.block_pickup_request_while_paused() from public, anon, authenticated;

create trigger pickup_requests_block_while_paused
  before insert on public.pickup_requests
  for each row execute function public.block_pickup_request_while_paused();

notify pgrst, 'reload schema';

commit;
