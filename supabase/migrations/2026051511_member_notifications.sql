-- 사이트 내 알림 센터 (P3 Sprint 3-1)
--
-- 1. member_notifications 테이블
-- 2. RPC: list_my_notifications, count_my_unread, mark_read, mark_all_read
-- 3. service_role용: admin_create_notification (cron/send-notification.js에서 호출)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.member_notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null,
  title text not null,
  body text null,
  ref_url text null,
  ref_type text null,
  ref_id bigint null,
  read_at timestamptz null,
  created_at timestamptz not null default now()
);

create index if not exists idx_member_notifications_user_recent
  on public.member_notifications (user_id, created_at desc);

create index if not exists idx_member_notifications_unread
  on public.member_notifications (user_id, created_at desc)
  where read_at is null;

alter table public.member_notifications enable row level security;

drop policy if exists member_notifications_select_own on public.member_notifications;
create policy member_notifications_select_own on public.member_notifications
  for select to authenticated
  using (user_id = auth.uid());

-- 사용자는 자기 알림 읽음 상태만 변경 가능 (그 외 컬럼 변경은 불가)
drop policy if exists member_notifications_update_own on public.member_notifications;
create policy member_notifications_update_own on public.member_notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists member_notifications_admin_all on public.member_notifications;
create policy member_notifications_admin_all on public.member_notifications
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 내 알림 목록
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_my_notifications(
  p_limit integer default 30,
  p_offset integer default 0,
  p_unread_only boolean default false
)
returns table (
  id bigint,
  type text,
  title text,
  body text,
  ref_url text,
  ref_type text,
  ref_id bigint,
  read_at timestamptz,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    mn.id, mn.type, mn.title, mn.body, mn.ref_url,
    mn.ref_type, mn.ref_id, mn.read_at, mn.created_at
  from public.member_notifications mn
  where mn.user_id = auth.uid()
    and (not p_unread_only or mn.read_at is null)
  order by mn.created_at desc
  limit greatest(p_limit, 1)
  offset greatest(p_offset, 0);
$$;

grant execute on function public.list_my_notifications(integer, integer, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 안 읽은 카운트 (헤더 배지용)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.count_my_unread_notifications()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.member_notifications
  where user_id = auth.uid()
    and read_at is null;
$$;

grant execute on function public.count_my_unread_notifications() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 단건 읽음
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_notification_read(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  update public.member_notifications
  set read_at = coalesce(read_at, now())
  where id = p_id and user_id = v_user;

  return jsonb_build_object('success', true, 'id', p_id);
end;
$$;

grant execute on function public.mark_notification_read(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 모두 읽음
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.mark_all_notifications_read()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  update public.member_notifications
  set read_at = now()
  where user_id = v_user and read_at is null;

  get diagnostics v_count = row_count;

  return jsonb_build_object('success', true, 'marked', v_count);
end;
$$;

grant execute on function public.mark_all_notifications_read() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- service_role 전용: 알림 생성 (send-notification.js / cron 에서 호출)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_create_member_notification(
  p_user_id uuid,
  p_type text,
  p_title text,
  p_body text default null,
  p_ref_url text default null,
  p_ref_type text default null,
  p_ref_id bigint default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  insert into public.member_notifications (
    user_id, type, title, body, ref_url, ref_type, ref_id
  ) values (
    p_user_id, p_type, p_title,
    nullif(btrim(coalesce(p_body, '')), ''),
    nullif(btrim(coalesce(p_ref_url, '')), ''),
    nullif(btrim(coalesce(p_ref_type, '')), ''),
    p_ref_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.admin_create_member_notification(uuid, text, text, text, text, text, bigint) from public;
revoke execute on function public.admin_create_member_notification(uuid, text, text, text, text, text, bigint) from authenticated;
grant execute on function public.admin_create_member_notification(uuid, text, text, text, text, text, bigint) to service_role;

commit;
