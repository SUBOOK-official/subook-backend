-- 휴대폰 SMS 인증(OTP) 기반 (2026-07-10)
--
-- 목적: 가입 쿠폰 어뷰징 방어(A+C안 — 쿠폰 수령 시점 인증, 인증된 번호당 1회)의 기반.
-- 발송은 public-web 서버리스 api/auth/send-phone-otp.js (솔라피 SMS, 레이트리밋 포함),
-- 검증은 아래 verify_phone_otp RPC. 코드는 평문 저장하지 않고 sha256(code || user_id) 해시만 저장.

begin;

create extension if not exists pgcrypto with schema extensions;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) member_profiles.phone_verified_at — 인증된 번호와 시각
--    (phone 컬럼 자체는 유지 — 인증 성공 시 인증했던 번호로 덮어쓰고 verified_at 기록.
--     이후 phone을 수동 수정하면 프론트/RPC가 verified_at을 신뢰하지 않도록
--     phone_verified_at은 "이 번호가 인증됨"의 페어인 phone_verified 컬럼과 함께 기록)
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.member_profiles
  add column if not exists phone_verified_at timestamptz null,
  add column if not exists verified_phone text null;

comment on column public.member_profiles.verified_phone is
  '마지막으로 SMS 인증을 통과한 전화번호(숫자만). phone과 별도 보관 — phone을 수정해도 인증 이력은 유지.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) OTP 코드 테이블 — RLS deny-all (service role + definer RPC만 접근)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.phone_verification_codes (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  phone text not null,                    -- 숫자만 정규화
  code_hash text not null,                -- sha256(code || user_id) hex
  expires_at timestamptz not null,
  attempt_count integer not null default 0,
  verified_at timestamptz null,
  created_at timestamptz not null default now()
);

create index if not exists idx_phone_verification_codes_user
  on public.phone_verification_codes (user_id, created_at desc);

create index if not exists idx_phone_verification_codes_phone
  on public.phone_verification_codes (phone, created_at desc);

alter table public.phone_verification_codes enable row level security;
-- 정책 없음 = authenticated/anon 직접 접근 전면 차단 (의도된 deny-all)

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 검증 RPC — 6자리 코드, 5분 만료, 5회 시도 제한
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.verify_phone_otp(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_row record;
  v_hash text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_row
  from public.phone_verification_codes
  where user_id = v_user_id
    and verified_at is null
    and expires_at > now()
  order by created_at desc
  limit 1;

  if not found then
    raise exception '유효한 인증 요청이 없습니다. 인증번호를 다시 받아 주세요.';
  end if;

  if v_row.attempt_count >= 5 then
    raise exception '시도 횟수를 초과했습니다. 인증번호를 다시 받아 주세요.';
  end if;

  update public.phone_verification_codes
  set attempt_count = attempt_count + 1
  where id = v_row.id;

  v_hash := encode(extensions.digest(btrim(p_code) || v_user_id::text, 'sha256'), 'hex');

  if v_hash <> v_row.code_hash then
    raise exception '인증번호가 일치하지 않습니다. (남은 시도 %회)', greatest(0, 4 - v_row.attempt_count);
  end if;

  update public.phone_verification_codes
  set verified_at = now()
  where id = v_row.id;

  update public.member_profiles
  set
    phone = v_row.phone,
    verified_phone = v_row.phone,
    phone_verified_at = now(),
    updated_at = now()
  where user_id = v_user_id;

  return jsonb_build_object(
    'success', true,
    'phone', v_row.phone,
    'verified_at', now()
  );
end;
$$;

grant execute on function public.verify_phone_otp(text) to authenticated;

commit;
