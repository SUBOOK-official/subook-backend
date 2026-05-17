-- FAQ + 공지사항 CMS (P3 Sprint 2-2)
--
-- 1. faqs 테이블: 운영자가 어드민에서 직접 관리
-- 2. notices 테이블: 공지사항 + 사이트 상단 핀 공지
-- 3. 공개 RPC: list_public_faqs, list_public_notices, list_public_pinned_notices
-- 4. 어드민 RPC: CRUD

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- FAQ 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.faqs (
  id bigint generated always as identity primary key,
  category text null,
  question text not null,
  answer text not null,
  display_order integer not null default 0,
  is_published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_faqs_published_order
  on public.faqs (display_order, id) where is_published = true;

alter table public.faqs enable row level security;

drop policy if exists faqs_public_select on public.faqs;
create policy faqs_public_select on public.faqs
  for select to anon, authenticated
  using (is_published = true);

drop policy if exists faqs_admin_all on public.faqs;
create policy faqs_admin_all on public.faqs
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- updated_at 자동 갱신
create or replace function public.touch_faqs_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists faqs_set_updated_at on public.faqs;
create trigger faqs_set_updated_at
  before update on public.faqs
  for each row execute function public.touch_faqs_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- 공지사항 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.notices (
  id bigint generated always as identity primary key,
  title text not null,
  body text not null,
  is_pinned boolean not null default false,
  is_published boolean not null default true,
  published_at timestamptz not null default now(),
  expires_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_notices_published_at
  on public.notices (published_at desc) where is_published = true;

create index if not exists idx_notices_pinned
  on public.notices (published_at desc)
  where is_pinned = true and is_published = true;

alter table public.notices enable row level security;

drop policy if exists notices_public_select on public.notices;
create policy notices_public_select on public.notices
  for select to anon, authenticated
  using (
    is_published = true
    and (expires_at is null or expires_at > now())
  );

drop policy if exists notices_admin_all on public.notices;
create policy notices_admin_all on public.notices
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create or replace function public.touch_notices_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists notices_set_updated_at on public.notices;
create trigger notices_set_updated_at
  before update on public.notices
  for each row execute function public.touch_notices_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- 공개 RPC: 게시된 FAQ
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_public_faqs()
returns table (
  id bigint,
  category text,
  question text,
  answer text,
  display_order integer
)
language sql stable security definer
set search_path = public
as $$
  select f.id, f.category, f.question, f.answer, f.display_order
  from public.faqs f
  where f.is_published = true
  order by f.display_order, f.id;
$$;

grant execute on function public.list_public_faqs() to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 공개 RPC: 게시된 공지사항 목록
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_public_notices(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id bigint,
  title text,
  body text,
  is_pinned boolean,
  published_at timestamptz,
  expires_at timestamptz
)
language sql stable security definer
set search_path = public
as $$
  select n.id, n.title, n.body, n.is_pinned, n.published_at, n.expires_at
  from public.notices n
  where n.is_published = true
    and (n.expires_at is null or n.expires_at > now())
  order by n.is_pinned desc, n.published_at desc
  limit greatest(p_limit, 1)
  offset greatest(p_offset, 0);
$$;

grant execute on function public.list_public_notices(integer, integer) to anon, authenticated;

-- 사이트 헤더에 띄울 핀 공지 (간단)
create or replace function public.list_public_pinned_notices()
returns table (
  id bigint,
  title text,
  body text,
  published_at timestamptz
)
language sql stable security definer
set search_path = public
as $$
  select n.id, n.title, n.body, n.published_at
  from public.notices n
  where n.is_published = true
    and n.is_pinned = true
    and (n.expires_at is null or n.expires_at > now())
  order by n.published_at desc
  limit 5;
$$;

grant execute on function public.list_public_pinned_notices() to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 어드민 CRUD RPC
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_upsert_faq(
  p_id bigint default null,
  p_category text default null,
  p_question text default '',
  p_answer text default '',
  p_display_order integer default 0,
  p_is_published boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_q text := nullif(btrim(coalesce(p_question, '')), '');
  v_a text := nullif(btrim(coalesce(p_answer, '')), '');
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if v_q is null then raise exception '질문(question)을 입력해 주세요.'; end if;
  if v_a is null then raise exception '답변(answer)을 입력해 주세요.'; end if;

  if p_id is null then
    insert into public.faqs (category, question, answer, display_order, is_published)
    values (nullif(btrim(coalesce(p_category, '')), ''), v_q, v_a,
            coalesce(p_display_order, 0), coalesce(p_is_published, true))
    returning id into v_id;
  else
    update public.faqs
    set category = nullif(btrim(coalesce(p_category, '')), ''),
        question = v_q,
        answer = v_a,
        display_order = coalesce(p_display_order, display_order),
        is_published = coalesce(p_is_published, is_published)
    where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'FAQ를 찾을 수 없습니다.'; end if;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_faq(bigint, text, text, text, integer, boolean) to authenticated;

create or replace function public.admin_delete_faq(p_id bigint)
returns jsonb language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  delete from public.faqs where id = p_id;
  return jsonb_build_object('success', true, 'id', p_id);
end;
$$;

grant execute on function public.admin_delete_faq(bigint) to authenticated;

create or replace function public.admin_upsert_notice(
  p_id bigint default null,
  p_title text default '',
  p_body text default '',
  p_is_pinned boolean default false,
  p_is_published boolean default true,
  p_published_at timestamptz default null,
  p_expires_at timestamptz default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if v_title is null then raise exception '제목을 입력해 주세요.'; end if;
  if v_body is null then raise exception '본문을 입력해 주세요.'; end if;

  if p_id is null then
    insert into public.notices (title, body, is_pinned, is_published, published_at, expires_at)
    values (v_title, v_body, coalesce(p_is_pinned, false), coalesce(p_is_published, true),
            coalesce(p_published_at, now()), p_expires_at)
    returning id into v_id;
  else
    update public.notices
    set title = v_title,
        body = v_body,
        is_pinned = coalesce(p_is_pinned, is_pinned),
        is_published = coalesce(p_is_published, is_published),
        published_at = coalesce(p_published_at, published_at),
        expires_at = p_expires_at
    where id = p_id
    returning id into v_id;
    if v_id is null then raise exception '공지를 찾을 수 없습니다.'; end if;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_notice(bigint, text, text, boolean, boolean, timestamptz, timestamptz) to authenticated;

create or replace function public.admin_delete_notice(p_id bigint)
returns jsonb language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  delete from public.notices where id = p_id;
  return jsonb_build_object('success', true, 'id', p_id);
end;
$$;

grant execute on function public.admin_delete_notice(bigint) to authenticated;

commit;
