-- complete_oauth_signup 시그니처를 확장 — OAuth/이메일 가입 미완료자 모두 사용 가능.
-- 사용자가 OTP 인증만 하고 약관·이름·연락처를 못 채운 채 떠난 경우, 다음 진입 시 동일 페이지에서
-- 비번/이름/연락처/약관을 한 번에 완성하기 위한 backend 지원.
--
-- 변경:
--   1) complete_oauth_signup(p_marketing_opt_in, p_name, p_phone) — name/phone 인자 추가
--   2) 함수명·동작은 OAuth와 동일하지만 이메일 가입자에게도 호출됨 (frontend가 동일 페이지를 재사용)
--
-- 비파괴적: 옛 시그니처 함수는 drop하지 않음 (PG가 default 인자 덕에 새 시그니처 호출도 옛 호출도 모두 라우팅).
--   단 default가 있어 1-arg/3-arg가 다른 함수로 인식되면 두 시그니처가 공존. 이걸 피하려 기존 시그니처
--   drop 후 새 시그니처로 재생성.

drop function if exists public.complete_oauth_signup(boolean);

create or replace function public.complete_oauth_signup(
  p_marketing_opt_in boolean default false,
  p_name text default null,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_now timestamptz := now();
  v_existing record;
  v_name text;
  v_phone text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_existing
  from public.member_profiles
  where user_id = v_user_id;

  if not found then
    raise exception 'Member profile not found. Signup callback may not have completed.';
  end if;

  v_name := nullif(btrim(coalesce(p_name, '')), '');
  v_phone := nullif(btrim(coalesce(p_phone, '')), '');

  update public.member_profiles
  set
    -- 이름·연락처는 입력 받으면 항상 덮어쓰기 (사용자가 이 화면에서 명시적으로 입력한 값)
    name = coalesce(v_name, name),
    nickname = coalesce(v_name, nickname),
    phone = coalesce(v_phone, phone),
    terms_agreed_at = coalesce(terms_agreed_at, v_now),
    privacy_agreed_at = coalesce(privacy_agreed_at, v_now),
    marketing_opt_in = coalesce(p_marketing_opt_in, false),
    marketing_agreed_at = case
      when coalesce(p_marketing_opt_in, false) then coalesce(marketing_agreed_at, v_now)
      else null
    end,
    updated_at = v_now
  where user_id = v_user_id;

  return jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'terms_agreed_at', coalesce(v_existing.terms_agreed_at, v_now),
    'privacy_agreed_at', coalesce(v_existing.privacy_agreed_at, v_now),
    'marketing_opt_in', coalesce(p_marketing_opt_in, false),
    'name', coalesce(v_name, v_existing.name),
    'phone', coalesce(v_phone, v_existing.phone)
  );
end;
$$;

grant execute on function public.complete_oauth_signup(boolean, text, text) to authenticated;
