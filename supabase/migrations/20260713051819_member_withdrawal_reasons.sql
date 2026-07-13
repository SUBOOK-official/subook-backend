-- 회원탈퇴 사유 수집·보관 (2026-07-13 요청)
--
-- 탈퇴 신청 시 이유(고정 선택지 + 기타 직접입력)를 물어 전부 보관한다.
-- 서비스 개선용 데이터이므로 개인정보 파기(purge) 후에도 행은 남긴다:
--   · user_id는 auth.users FK지만 on delete set null — 계정이 삭제돼도 사유는 익명으로 유지
--   · purge_expired_member_personal_data는 이 테이블을 건드리지 않음 (익명 통계 데이터)
--   · reason_category = 집계용 고정 키, reason_label = 선택 당시 문구 스냅샷(카피 변경 대비),
--     reason_detail = 기타 직접입력/부가 설명
--
-- RPC 시그니처 변경 주의:
--   기존 request_member_withdrawal()  (무인자, 20260602040000)을 drop하고
--   request_member_withdrawal(text, text, text)  (모두 default null)로 재생성한다.
--   무인자 버전을 남기면 인자 없는 호출이 두 오버로드 사이에서 모호해지므로 반드시 drop.
--   구버전 프론트(배포 전)의 무인자 호출은 default 인자로 정상 동작한다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 사유 보관 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.member_withdrawal_reasons (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  reason_category text not null,
  reason_label text,
  reason_detail text,
  created_at timestamptz not null default now()
);

comment on table public.member_withdrawal_reasons is
  '회원탈퇴 사유 설문 — 파기 후에도 통계용으로 보관 (2026-07-13). insert는 request_member_withdrawal RPC 전용';

create index if not exists idx_member_withdrawal_reasons_created_at
  on public.member_withdrawal_reasons (created_at desc);

alter table public.member_withdrawal_reasons enable row level security;

-- 조회는 운영자만. insert/update/delete 정책은 없음 —
-- 쓰기는 security definer RPC(request_member_withdrawal)만 수행한다.
drop policy if exists "Admins can read withdrawal reasons" on public.member_withdrawal_reasons;
create policy "Admins can read withdrawal reasons"
  on public.member_withdrawal_reasons
  for select
  using (public.is_admin_user());

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) RPC: 사유 인자 추가 (base: 20260602040000_drift_repair_privacy_and_reviews.sql)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.request_member_withdrawal();

create or replace function public.request_member_withdrawal(
  p_reason_category text default null,
  p_reason_label text default null,
  p_reason_detail text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz := now();
  v_scheduled_at timestamptz := now() + interval '30 days';
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  update public.member_profiles
  set
    withdrawal_requested_at = coalesce(withdrawal_requested_at, v_requested_at),
    withdrawal_scheduled_at = coalesce(withdrawal_scheduled_at, v_scheduled_at),
    marketing_opt_in = false, updated_at = now()
  where user_id = v_user_id and personal_data_erased_at is null;
  if not found then raise exception 'Member profile not found'; end if;
  delete from public.cart_items where user_id = v_user_id;

  -- 탈퇴 사유 보관 — 카테고리가 온 경우에만. 길이 상한으로 임의 payload 방어.
  if nullif(btrim(coalesce(p_reason_category, '')), '') is not null then
    insert into public.member_withdrawal_reasons (user_id, reason_category, reason_label, reason_detail)
    values (
      v_user_id,
      left(btrim(p_reason_category), 64),
      nullif(left(btrim(coalesce(p_reason_label, '')), 200), ''),
      nullif(left(btrim(coalesce(p_reason_detail, '')), 2000), '')
    );
  end if;

  return jsonb_build_object('success', true, 'withdrawal_requested_at', v_requested_at, 'withdrawal_scheduled_at', v_scheduled_at);
end;
$$;

grant execute on function public.request_member_withdrawal(text, text, text) to authenticated;

commit;
