-- 프로필 동기화 트리거 하드닝 (2026-07-24)
--
-- 문제: sync_member_profile_from_auth의 ON CONFLICT UPSERT가 auth.users가 갱신될 때마다
--       member_profiles의 phone/name/nickname/marketing_opt_in을 auth 메타데이터 값으로
--       무조건 덮어썼다. 마이페이지에서 전화번호를 수정한 회원이 비밀번호 재설정 등으로
--       auth 레코드를 터치하면 옛 메타데이터 값으로 롤백되는 버그.
--       (2026-07-24 레거시 계정 사전 생성 때 전화 393건·마케팅 동의 206건이 실제로
--        지워지는 사고로 발견 — tools/legacy_repair_metadata.mjs로 수리 완료)
--
-- 원칙: 최초 INSERT는 기존대로 메타데이터로 시드하되, 기존 프로필이 있으면(ON CONFLICT)
--       - phone/name/nickname: 프로필 값이 비어 있을 때만 메타데이터로 보충 (사용자 입력 보호)
--       - marketing_opt_in/marketing_agreed_at: 프로필 값 유지 (가입 후에는 마이페이지·RPC가 관리)
--       - email/email_verified_at: 기존 로직 유지 (auth가 이메일의 단일 소스)
--       - terms/privacy_agreed_at: 기존 coalesce(프로필 우선) 유지
--
-- 참고: 메타데이터→프로필 일괄 전파가 필요하면(레거시 수리 같은 운영 작업) 프로필 컬럼을
--       직접 UPDATE할 것. 이 트리거는 더 이상 기존 프로필 값을 밀어내지 않는다.

create or replace function public.sync_member_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  next_email text;
  next_name text;
  next_nickname text;
  next_phone text;
  next_marketing_opt_in boolean := false;
  next_terms_agreed_at timestamptz;
  next_privacy_agreed_at timestamptz;
  next_marketing_agreed_at timestamptz;
  next_email_verified_at timestamptz;
  is_oauth_user boolean := false;
  v_meta_terms_text text;
  v_meta_privacy_text text;
  v_meta_marketing_text text;
begin
  next_email := lower(coalesce(nullif(btrim(new.email), ''), new.id::text || '@oauth.subook.local'));
  next_email_verified_at := new.email_confirmed_at;

  if exists (
    select 1
    from public.member_profiles mp
    where mp.user_id = new.id
      and mp.withdrawal_requested_at is not null
  ) then
    return new;
  end if;

  -- OAuth provider 판별
  is_oauth_user := new.raw_app_meta_data is not null
    and new.raw_app_meta_data ->> 'provider' is not null
    and new.raw_app_meta_data ->> 'provider' <> 'email';

  -- OAuth는 email_confirmed_at이 없어도 인증된 것으로 처리 (네이버/카카오 등)
  if next_email_verified_at is null and is_oauth_user then
    next_email_verified_at := coalesce(new.email_confirmed_at, new.created_at, now());
  end if;

  next_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), '');
  next_nickname := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'nickname', '')), '');
  next_phone := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'phone', '')), '');
  next_marketing_opt_in := case lower(coalesce(new.raw_user_meta_data ->> 'marketing_opt_in', ''))
    when 'true' then true
    when '1' then true
    when 'yes' then true
    when 'on' then true
    else false
  end;

  -- 명시 메타데이터에 동의 시각이 있을 때만 채움. 없으면 NULL.
  v_meta_terms_text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'terms_agreed_at', '')), '');
  v_meta_privacy_text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'privacy_agreed_at', '')), '');
  v_meta_marketing_text := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'marketing_agreed_at', '')), '');

  if v_meta_terms_text is not null then
    next_terms_agreed_at := v_meta_terms_text::timestamptz;
  elsif is_oauth_user then
    -- OAuth는 명시 동의 전까지 NULL (complete_oauth_signup RPC에서 채움)
    next_terms_agreed_at := null;
  else
    -- 이메일 가입 시 메타데이터 누락 케이스 — 기존 behavior 유지
    next_terms_agreed_at := coalesce(new.created_at, now());
  end if;

  if v_meta_privacy_text is not null then
    next_privacy_agreed_at := v_meta_privacy_text::timestamptz;
  elsif is_oauth_user then
    next_privacy_agreed_at := null;
  else
    next_privacy_agreed_at := coalesce(new.created_at, now());
  end if;

  next_marketing_agreed_at := case
    when not next_marketing_opt_in then null
    when v_meta_marketing_text is not null then v_meta_marketing_text::timestamptz
    when is_oauth_user then null
    else coalesce(new.created_at, now())
  end;

  insert into public.member_profiles (
    user_id,
    email,
    name,
    nickname,
    phone,
    marketing_opt_in,
    terms_agreed_at,
    privacy_agreed_at,
    marketing_agreed_at,
    email_verified_at
  )
  values (
    new.id,
    next_email,
    coalesce(next_name, split_part(next_email, '@', 1)),
    coalesce(next_nickname, next_name, split_part(next_email, '@', 1)),
    next_phone,
    next_marketing_opt_in,
    next_terms_agreed_at,
    next_privacy_agreed_at,
    next_marketing_agreed_at,
    next_email_verified_at
  )
  on conflict (user_id) do update
  set
    email = excluded.email,
    -- 하드닝: 프로필에 이미 값이 있으면 유지, 비어 있을 때만 메타데이터로 보충
    name = coalesce(nullif(btrim(public.member_profiles.name), ''), excluded.name),
    nickname = coalesce(nullif(btrim(public.member_profiles.nickname), ''), excluded.nickname),
    phone = coalesce(nullif(btrim(public.member_profiles.phone), ''), excluded.phone),
    -- 하드닝: 마케팅 동의는 가입 이후 마이페이지·RPC가 단일 관리 주체 — 트리거는 불변
    marketing_opt_in = public.member_profiles.marketing_opt_in,
    marketing_agreed_at = public.member_profiles.marketing_agreed_at,
    terms_agreed_at = coalesce(public.member_profiles.terms_agreed_at, excluded.terms_agreed_at),
    privacy_agreed_at = coalesce(public.member_profiles.privacy_agreed_at, excluded.privacy_agreed_at),
    email_verified_at = case
      when public.member_profiles.email = excluded.email
        then coalesce(public.member_profiles.email_verified_at, excluded.email_verified_at)
      else excluded.email_verified_at
    end,
    updated_at = now();

  begin
    if next_phone is not null and to_regclass('public.shipments') is not null then
      update public.shipments s
      set user_id = new.id
      where s.user_id is null
        and s.seller_name = coalesce(next_name, split_part(next_email, '@', 1))
        and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
          regexp_replace(next_phone, '[^0-9]', '', 'g');
    end if;
  exception
    when undefined_table or undefined_column then
      null;
  end;

  return new;
end;
$function$;
