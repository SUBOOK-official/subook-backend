-- 회원 CS 메모 (감사 P2 → R2 IA 개편에서 구현)
--
-- 위탁 특성상 환불 협의·계좌 오류·검수 분쟁 같은 반복 CS가 잦은데
-- 회원 상세에 응대 이력을 남길 곳이 없어 담당자 교대·재문의 시 맥락이 유실됐다.
-- 접근 모델: notification_logs_admin_all과 동일하게 직접 테이블 + admin 전용 RLS
-- (admin-web이 anon key + is_admin_user() 정책으로 select/insert).

create table if not exists public.member_notes (
  id bigint generated always as identity primary key,
  member_user_id uuid not null references auth.users(id) on delete cascade,
  -- 작성자 — 계정 삭제에도 표시가 남도록 이메일 스냅샷을 함께 저장
  author_user_id uuid null default auth.uid() references auth.users(id) on delete set null,
  author_email text null,
  note text not null check (char_length(btrim(note)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists idx_member_notes_member
  on public.member_notes (member_user_id, created_at desc);

comment on table public.member_notes is
  '운영자 CS 응대 메모 — 회원 상세 타임라인. admin 전용(RLS).';

alter table public.member_notes enable row level security;

drop policy if exists member_notes_admin_all on public.member_notes;
create policy member_notes_admin_all
  on public.member_notes for all
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());
