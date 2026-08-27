-- 전일학원 콜라보 출시 알림 신청 (2026-08-27)
--
-- /event/jeon-il 의 알림 신청 다이얼로그(전화번호 + 마케팅 수신 동의)가 저장할 테이블 + RPC.
-- 비회원도 신청 가능해야 하므로 RPC는 anon 실행 허용, 테이블 직접 접근은 전면 차단.
--
-- 정책:
--   · (event_key, phone) 유니크 — 같은 번호 재신청은 멱등 성공 (ALREADY)
--   · 마케팅 동의 필수(다이얼로그와 동일), 동의 시각 저장
--   · 로그인 상태면 user_id도 기록
--   · 별도 OTP/레이트리밋 없음 — 가입 쿠폰과 동일한 수용 리스크(7/28 정책 패턴).
--     발송(9/3 문자 블라스트)은 어드민 수동 트리거라 발송 전 목록 확인으로 방어.
--   · 보유기간: 이벤트 종료 후 6개월 (다이얼로그 약관 문구) — 파기는 privacy purge 크론에
--     추가 예정(별도 마이그레이션). notified_at은 발송 잡 멱등 처리용.
--
-- 비파괴: 신규 테이블 + CREATE FUNCTION.

begin;

create table if not exists public.event_subscriptions (
  id bigint generated always as identity primary key,
  event_key text not null,
  phone text not null,
  marketing_consent_at timestamptz not null,
  user_id uuid null references auth.users(id) on delete set null,
  notified_at timestamptz null,
  created_at timestamptz not null default now(),
  unique (event_key, phone)
);

comment on table public.event_subscriptions is
  '이벤트 출시 알림 신청 (전화번호 기반, 비회원 포함). 접근은 submit_event_subscription RPC와 service_role만.';

create index if not exists idx_event_subscriptions_event_notified
  on public.event_subscriptions (event_key, notified_at);

-- RLS: 정책 없이 enable → anon/authenticated 직접 접근 전면 차단 (definer RPC·service_role만)
alter table public.event_subscriptions enable row level security;

create or replace function public.submit_event_subscription(
  p_event_key text,
  p_phone text,
  p_marketing_consent boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_inserted boolean;
begin
  -- 이벤트 키 allowlist — 새 이벤트를 열 때만 여기에 추가
  if p_event_key is distinct from 'jeonil-2026-09' then
    return jsonb_build_object('success', false, 'code', 'INVALID_EVENT');
  end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if v_phone !~ '^01[016789][0-9]{7,8}$' then
    return jsonb_build_object('success', false, 'code', 'INVALID_PHONE');
  end if;

  if p_marketing_consent is distinct from true then
    return jsonb_build_object('success', false, 'code', 'CONSENT_REQUIRED');
  end if;

  insert into public.event_subscriptions (event_key, phone, marketing_consent_at, user_id)
  values (p_event_key, v_phone, now(), auth.uid())
  on conflict (event_key, phone) do nothing;

  v_inserted := found;

  return jsonb_build_object(
    'success', true,
    'code', case when v_inserted then 'SUBSCRIBED' else 'ALREADY' end
  );
end;
$$;

revoke all on function public.submit_event_subscription(text, text, boolean) from public;
grant execute on function public.submit_event_subscription(text, text, boolean) to anon, authenticated, service_role;

commit;
