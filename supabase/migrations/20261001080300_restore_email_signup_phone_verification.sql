-- 이메일/소셜 가입 유지. 이메일 가입의 SMS 증명은 Auth 계정 생성 전에 확보한다.
-- OAuth의 내부 인증 레코드는 콜백에 필요하지만 회원 프로필은 번호 확인 후에만 만든다.
-- 롤백: before-user-created hook 해제 후 이전 앱으로 복귀. 증명/회원/통합 원장은 보존.
begin;
create table public.member_signup_phone_challenges (
  id uuid primary key,
  email text not null,
  phone text not null check(phone ~ '^010[0-9]{8}$'),
  secret_hash text not null,
  code_hash text not null,
  ip_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '5 minutes',
  attempt_count integer not null default 0,
  verified_at timestamptz,
  claimed_user_id uuid,
  claimed_at timestamptz
);
create index member_signup_phone_challenges_ip_time on public.member_signup_phone_challenges(ip_hash,created_at);
alter table public.member_signup_phone_challenges enable row level security;
revoke all on public.member_signup_phone_challenges from public,anon,authenticated;

create function public.reserve_signup_phone_challenge(p_id uuid,p_email text,p_phone text,p_secret_hash text,p_code_hash text,p_ip_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_phone text:=public.normalize_member_phone(p_phone); v_result jsonb;
begin
  if length(p_email)>254 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or p_secret_hash !~ '^[a-f0-9]{64}$' or p_code_hash !~ '^[a-f0-9]{64}$' or p_ip_hash !~ '^[a-f0-9]{64}$' then
    raise exception '입력 정보를 확인해 주세요.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('signup-ip:'||p_ip_hash,0));
  if (select count(*) from public.member_signup_phone_challenges where ip_hash=p_ip_hash and created_at>now()-interval '1 day')>=20 then
    return jsonb_build_object('success',false,'error','인증 요청 한도를 초과했습니다. 잠시 후 다시 시도해 주세요.');
  end if;
  v_result:=public.reserve_member_auth_sms(v_phone);
  if not coalesce((v_result->>'success')::boolean,false) then return v_result; end if;
  insert into public.member_signup_phone_challenges(id,email,phone,secret_hash,code_hash,ip_hash)
    values(p_id,lower(btrim(p_email)),v_phone,p_secret_hash,p_code_hash,p_ip_hash);
  return jsonb_build_object('success',true);
end;
$$;
create function public.verify_signup_phone_challenge(p_id uuid,p_secret_hash text,p_code_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_row public.member_signup_phone_challenges%rowtype;
begin
  select * into v_row from public.member_signup_phone_challenges where id=p_id and secret_hash=p_secret_hash for update;
  if not found or v_row.expires_at<=now() or v_row.attempt_count>=5 or v_row.claimed_at is not null then
    return jsonb_build_object('success',false,'error','인증 요청이 만료됐습니다. 인증번호를 다시 받아 주세요.');
  end if;
  if v_row.code_hash<>p_code_hash then
    update public.member_signup_phone_challenges set attempt_count=attempt_count+1 where id=p_id;
    return jsonb_build_object('success',false,'error','인증번호가 일치하지 않습니다.');
  end if;
  update public.member_signup_phone_challenges set verified_at=coalesce(verified_at,now()),expires_at=now()+interval '20 minutes' where id=p_id;
  return jsonb_build_object('success',true,'phone',v_row.phone);
end;
$$;
revoke all on function public.reserve_signup_phone_challenge(uuid,text,text,text,text,text),public.verify_signup_phone_challenge(uuid,text,text) from public,anon,authenticated;
grant execute on function public.reserve_signup_phone_challenge(uuid,text,text,text,text,text),public.verify_signup_phone_challenge(uuid,text,text) to service_role;

-- metadata 자체는 신뢰하지 않는다. 이메일에 묶인 일회성 서버 증명만 허용한다.
create function public.before_member_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_email text:=lower(btrim(event->'user'->>'email')); v_provider text:=event->'user'->'app_metadata'->>'provider';
  v_id text:=event->'user'->'user_metadata'->>'signup_phone_id'; v_secret text:=event->'user'->'user_metadata'->>'signup_phone_secret';
begin
  if v_email is null or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','이메일이 있는 계정으로 가입해 주세요.'));
  end if;
  if v_provider in ('kakao','google') then return '{}'::jsonb; end if;
  if v_provider<>'email' or v_id is null or v_id !~ '^[a-f0-9-]{36}$' or v_secret is null or length(v_secret)<>64 then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','회원가입 화면에서 휴대폰 인증을 먼저 완료해 주세요.'));
  end if;
  if not exists(select 1 from public.member_signup_phone_challenges where id=v_id::uuid and email=v_email
    and secret_hash=encode(extensions.digest(v_secret,'sha256'),'hex') and verified_at is not null and expires_at>now() and claimed_at is null) then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','휴대폰 인증이 만료됐습니다. 다시 인증해 주세요.'));
  end if;
  return '{}'::jsonb;
end;
$$;
revoke all on function public.before_member_user_created(jsonb) from public,anon,authenticated;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.before_member_user_created(jsonb) to supabase_auth_admin;

create function public.claim_signup_phone_challenge() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_id text:=new.raw_user_meta_data->>'signup_phone_id'; v_secret text:=new.raw_user_meta_data->>'signup_phone_secret'; v_phone text;
begin
  if v_id is null or v_id !~ '^[a-f0-9-]{36}$' or v_secret is null then return new; end if;
  update public.member_signup_phone_challenges set claimed_user_id=new.id,claimed_at=now()
    where id=v_id::uuid and email=lower(new.email) and secret_hash=encode(extensions.digest(v_secret,'sha256'),'hex')
      and verified_at is not null and expires_at>now() and claimed_at is null returning phone into v_phone;
  if v_phone is null then raise exception '휴대폰 인증을 다시 진행해 주세요.'; end if;
  perform public._claim_member_phone(new.id,v_phone);
  return new;
end;
$$;
create trigger zz_claim_signup_phone_challenge after insert on auth.users for each row execute function public.claim_signup_phone_challenge();
revoke all on function public.claim_signup_phone_challenge() from public,anon,authenticated;

-- 서버가 카카오 API의 인증된 번호·회원번호를 확인한 뒤에만 호출한다.
create function public.claim_kakao_member_phone(p_user_id uuid,p_phone text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from auth.users where id=p_user_id and nullif(email,'') is not null)
    or exists(select 1 from public.member_profiles where user_id=p_user_id and
      (coalesce(is_blocked,false) or withdrawal_requested_at is not null or personal_data_erased_at is not null)) then
    raise exception '이용할 수 없는 계정입니다.';
  end if;
  return public._claim_member_phone(p_user_id,p_phone);
end;
$$;
revoke all on function public.claim_kakao_member_phone(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_kakao_member_phone(uuid,text) to service_role;

-- 신규 회원 데이터는 인증 번호와 실제 이메일이 갖춰진 시점에 생성한다.
create function public.ensure_verified_member_profile(p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  insert into public.member_profiles(user_id,email,name,nickname,phone,verified_phone,phone_verified_at,email_verified_at)
  select u.id,lower(u.email),coalesce(nullif(u.raw_user_meta_data->>'name',''),split_part(u.email,'@',1)),
    coalesce(nullif(u.raw_user_meta_data->>'name',''),split_part(u.email,'@',1)),coalesce(i.phone,p.phone),i.phone,i.verified_at,u.email_confirmed_at
    from auth.users u join public.member_phone_proofs p on p.user_id=u.id and p.expires_at>now()
      left join public.member_phone_identities i on i.user_id=u.id
    where u.id=p_user_id and nullif(u.email,'') is not null
  on conflict(user_id) do nothing;
end;
$$;
revoke all on function public.ensure_verified_member_profile(uuid) from public,anon,authenticated;

create or replace function public.member_identity_is_ready() returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null
    and not exists(select 1 from public.member_account_merges where source_user_id=auth.uid())
    and (not (select enabled from public.member_identity_policy where singleton)
      or (exists(select 1 from public.member_phone_identities where user_id=auth.uid())
        and exists(select 1 from auth.users where id=auth.uid() and nullif(email,'') is not null and email_confirmed_at is not null)));
$$;

create or replace function public.get_member_identity_policy() returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('enabled',enabled,'phone_signup_enabled',false,'merge_enabled',merge_enabled,
    'email_required',true,'legacy_phone_login_enabled',exists(select 1 from auth.users where raw_app_meta_data->>'provider'='phone' and nullif(email,'') is null))
    from public.member_identity_policy where singleton;
$$;

-- 후속 함수 정의
create or replace function public._claim_member_phone(p_user_id uuid,p_phone text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_phone text:=public.normalize_member_phone(p_phone); v_owner uuid;
begin
  if v_phone !~ '^010[0-9]{8}$' then raise exception '국내 휴대폰 번호를 확인해 주세요.'; end if;
  if exists(select 1 from public.member_account_merges where source_user_id=p_user_id) then
    return jsonb_build_object('success',false,'status','merged','error','통합된 계정입니다. 대표 계정으로 로그인해 주세요.');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('member-phone:'||v_phone,0));
  insert into public.member_phone_proofs(user_id,phone,verified_at,expires_at)
    values(p_user_id,v_phone,now(),now()+interval '20 minutes')
    on conflict(user_id) do update set phone=excluded.phone,verified_at=excluded.verified_at,expires_at=excluded.expires_at;
  perform public.ensure_verified_member_profile(p_user_id);
  select user_id into v_owner from public.member_phone_identities where phone=v_phone;
  if exists(select 1 from public.member_phone_identities where user_id=p_user_id and phone<>v_phone) then
    return jsonb_build_object('success',false,'status','phone_change_required','error','이미 인증된 번호가 있습니다. 번호 변경은 고객센터로 문의해 주세요.');
  end if;
  if v_owner is not null and v_owner<>p_user_id then
    return jsonb_build_object('success',true,'status','merge_required','phone',v_phone);
  end if;
  if v_owner is null and exists(select 1 from public.member_profiles m join public.member_legacy_phone_accounts l on l.user_id=m.user_id
    where m.user_id<>p_user_id and l.phone=v_phone
      and m.personal_data_erased_at is null
      and not exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone<>v_phone)
      and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id)) then
    return jsonb_build_object('success',true,'status','merge_required','phone',v_phone);
  end if;
  insert into public.member_phone_identities(phone,user_id) values(v_phone,p_user_id)
    on conflict(phone) do update set verified_at=now() where member_phone_identities.user_id=p_user_id;
  perform public.ensure_verified_member_profile(p_user_id);
  update public.member_profiles set verified_phone=v_phone,phone=v_phone,phone_verified_at=now(),updated_at=now() where user_id=p_user_id;
  return jsonb_build_object('success',true,'status','verified','phone',v_phone);
end;
$$;


CREATE OR REPLACE FUNCTION public.sync_member_profile_from_auth()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if not exists(select 1 from public.member_profiles where user_id=new.id)
    and not exists(select 1 from public.member_phone_identities where user_id=new.id) then return new; end if;
  if nullif(btrim(new.email),'') is null then return new; end if;
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
    and new.raw_app_meta_data ->> 'provider' in ('kakao','google');

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
  elsif is_oauth_user or new.raw_app_meta_data->>'provider'='phone' then
    -- OAuth는 명시 동의 전까지 NULL (complete_oauth_signup RPC에서 채움)
    next_terms_agreed_at := null;
  else
    -- 이메일 가입 시 메타데이터 누락 케이스 — 기존 behavior 유지
    next_terms_agreed_at := null;
  end if;

  if v_meta_privacy_text is not null then
    next_privacy_agreed_at := v_meta_privacy_text::timestamptz;
  elsif is_oauth_user or new.raw_app_meta_data->>'provider'='phone' then
    next_privacy_agreed_at := null;
  else
    next_privacy_agreed_at := null;
  end if;

  next_marketing_agreed_at := case
    when not next_marketing_opt_in then null
    when v_meta_marketing_text is not null then v_meta_marketing_text::timestamptz
    when is_oauth_user or new.raw_app_meta_data->>'provider'='phone' then null
    else coalesce(new.created_at, now())
  end;

  next_terms_agreed_at := null;
  next_privacy_agreed_at := null;
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
    if next_phone is not null and to_regclass('public.shipments') is not null
      and not (select enabled from public.member_identity_policy where singleton) then
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
$function$
;

CREATE OR REPLACE FUNCTION public.complete_oauth_signup(p_marketing_opt_in boolean DEFAULT false, p_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  if not exists(select 1 from auth.users where id=v_user_id and nullif(email,'') is not null and email_confirmed_at is not null) then
    raise exception '이메일 인증을 먼저 완료해 주세요.';
  end if;
  perform public.assert_member_not_blocked();
  if (select enabled from public.member_identity_policy where singleton)
     and not exists(select 1 from public.member_phone_identities where user_id=v_user_id) then
    raise exception '휴대폰 인증을 먼저 완료해 주세요.';
  end if;

  select * into v_existing
  from public.member_profiles
  where user_id = v_user_id;

  if not found then
    raise exception 'Member profile not found. Signup callback may not have completed.';
  end if;

  v_name := nullif(btrim(coalesce(p_name, '')), '');
  v_phone := nullif(btrim(coalesce(p_phone, '')), '');
  if (select enabled from public.member_identity_policy where singleton) then
    select phone into v_phone from public.member_phone_identities where user_id=v_user_id;
  end if;

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
$function$
;

create or replace function public.reserve_member_phone_otp(p_user_id uuid,p_phone text,p_code_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_phone text:=public.normalize_member_phone(p_phone); v_result jsonb;
begin
  if not exists(select 1 from auth.users where id=p_user_id and nullif(email,'') is not null)
    or exists(select 1 from public.member_profiles where user_id=p_user_id and (coalesce(is_blocked,false)
      or withdrawal_requested_at is not null or personal_data_erased_at is not null))
    or exists(select 1 from public.member_account_merges where source_user_id=p_user_id) then
    return jsonb_build_object('success',false,'error','이용할 수 없는 계정입니다.');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('phone-otp-user:'||p_user_id::text,0));
  if exists(select 1 from public.phone_verification_codes where user_id=p_user_id and created_at>now()-interval '60 seconds')
    or (select count(*) from public.phone_verification_codes where user_id=p_user_id and created_at>now()-interval '1 day')>=5 then
    return jsonb_build_object('success',false,'error','인증 요청 한도를 초과했습니다. 잠시 후 다시 시도해 주세요.');
  end if;
  v_result:=public.reserve_member_auth_sms(v_phone);
  if not (v_result->>'success')::boolean then return v_result; end if;
  insert into public.phone_verification_codes(user_id,phone,code_hash,expires_at)
    values(p_user_id,v_phone,p_code_hash,now()+interval '5 minutes');
  return jsonb_build_object('success',true);
end;
$$;
revoke all on function public.reserve_member_phone_otp(uuid,text,text) from public,anon,authenticated;
grant execute on function public.reserve_member_phone_otp(uuid,text,text) to service_role;


create or replace function public.reserve_member_auth_sms_hook(p_phone text,p_hook_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_result jsonb; v_existing public.member_auth_sms_attempts%rowtype;
begin
  if not exists(select 1 from auth.users where public.normalize_member_phone(phone)=public.normalize_member_phone(p_phone) and phone_confirmed_at is not null) then
    return jsonb_build_object('success',false,'error','휴대폰 로그인을 준비 중입니다.');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('sms-hook:'||p_hook_id,0));
  select * into v_existing from public.member_auth_sms_attempts where hook_id=p_hook_id;
  if found then return jsonb_build_object('success',false,'sent',v_existing.sent_at is not null,
    'error','처리 중인 요청입니다. 1분 후 다시 요청해 주세요.'); end if;
  v_result:=public.reserve_member_auth_sms(p_phone);
  if not (v_result->>'success')::boolean then return v_result; end if;
  update public.member_auth_sms_attempts set hook_id=p_hook_id
    where id=(select max(id) from public.member_auth_sms_attempts where phone=public.normalize_member_phone(p_phone));
  return jsonb_build_object('success',true);
end;
$$;

create or replace function public._issue_verified_signup_coupons(p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_coupon public.coupons%rowtype; v_phone text; v_enabled boolean; v_activated timestamptz;
begin
  if not exists(select 1 from auth.users where id=p_user_id and nullif(email,'') is not null and email_confirmed_at is not null) then return; end if;
  select enabled,activated_at into v_enabled,v_activated from public.member_identity_policy where singleton;
  if exists(select 1 from public.admin_users a join public.member_profiles m on lower(a.email)=lower(m.email) where m.user_id=p_user_id) then return; end if;
  select phone into v_phone from public.member_phone_identities where user_id=p_user_id;
  if v_enabled and (v_phone is null or not exists(select 1 from public.member_profiles m join auth.users u on u.id=m.user_id
    where m.user_id=p_user_id and m.terms_agreed_at is not null and m.privacy_agreed_at is not null
      and u.created_at>=v_activated and not coalesce(m.is_blocked,false))
    or exists(select 1 from public.member_account_merges where source_user_id=p_user_id or target_user_id=p_user_id)) then return; end if;
  for v_coupon in select * from public.coupons where issue_on_signup and is_active
    and (valid_from is null or valid_from<=now()) and (valid_until is null or valid_until>=now()) order by id for update loop
    if v_coupon.issued_count>=v_coupon.total_quantity or exists(select 1 from public.member_coupons where coupon_id=v_coupon.id and user_id=p_user_id) then continue; end if;
    if v_enabled then
      insert into public.member_signup_benefit_claims(phone_fingerprint,coupon_id,user_id) values(public._member_phone_fingerprint(v_phone),v_coupon.id,p_user_id) on conflict do nothing;
      if not found then continue; end if;
    end if;
    insert into public.member_coupons(coupon_id,user_id,expires_at)
      values(v_coupon.id,p_user_id,public.compute_coupon_member_expiry(v_coupon.valid_days,v_coupon.valid_until));
    update public.coupons set issued_count=issued_count+1 where id=v_coupon.id;
  end loop;
end;
$$;
create or replace function public._referral_member_ready(p_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.member_profiles m join auth.users u on u.id=m.user_id where m.user_id=p_user_id
    and nullif(u.email,'') is not null and u.email_confirmed_at is not null
    and terms_agreed_at is not null and privacy_agreed_at is not null and not coalesce(is_blocked,false)
    and withdrawal_requested_at is null and personal_data_erased_at is null
    and not exists(select 1 from public.member_account_merges where source_user_id=p_user_id)
    and (case when (select enabled from public.member_identity_policy where singleton)
      then exists(select 1 from public.member_phone_identities where user_id=p_user_id)
      else email_verified_at is not null end));
$$;

CREATE OR REPLACE FUNCTION public._complete_signup_referral(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_signup public.member_referral_signups%rowtype;
  v_auth auth.users%rowtype;
  v_inviter public.coupons%rowtype;
  v_friend public.coupons%rowtype;
  v_inviter_coupon bigint; v_friend_coupon bigint;
  v_phone text; v_inviter_phone text; v_enabled boolean;
begin
  select * into v_signup from public.member_referral_signups where invitee_id = p_user_id for update;
  if not found then return jsonb_build_object('status', 'not_eligible'); end if;
  if v_signup.rewarded_at is not null then return jsonb_build_object('status', 'rewarded'); end if;
  select enabled into v_enabled from public.member_identity_policy where singleton;
  select * into v_auth from auth.users where id = p_user_id;
  if v_enabled then
    select phone into v_phone from public.member_phone_identities where user_id=p_user_id;
    select phone into v_inviter_phone from public.member_phone_identities where user_id=v_signup.inviter_id;
    if v_phone is null or (v_signup.inviter_id is not null and v_inviter_phone is null) then
      return jsonb_build_object('status','pending');
    end if;
    if v_phone=v_inviter_phone or exists(select 1 from public.member_account_merges
      where source_user_id=p_user_id or target_user_id=p_user_id or source_user_id=v_signup.inviter_id) then
      return jsonb_build_object('status','not_eligible');
    end if;
  end if;
  if not exists (select 1 from public.member_profiles where user_id = p_user_id
      and terms_agreed_at is not null and privacy_agreed_at is not null
      and not coalesce(is_blocked, false) and withdrawal_requested_at is null and personal_data_erased_at is null)
    or nullif(v_auth.email,'') is null or v_auth.email_confirmed_at is null then
    return jsonb_build_object('status', 'pending');
  end if;
  -- 이메일 OTP는 인증 시 임시 계정이 생성된다. 비밀번호/명시 동의 저장까지 기다린다.
  if coalesce(v_auth.raw_app_meta_data->>'provider', 'email') = 'email'
    and coalesce(v_auth.encrypted_password, '') = '' then
    return jsonb_build_object('status', 'pending');
  end if;
  update public.member_referral_signups set completed_at = coalesce(completed_at, now()) where invitee_id = p_user_id;
  if v_signup.inviter_id is null then return jsonb_build_object('status', 'no_referral'); end if;
  -- 같은 초대 링크로 가입을 동시에 완료해도 한 쌍만 받는다.
  perform 1 from public.member_referral_codes where user_id = v_signup.inviter_id for update;
  if public._referral_inviter_used(v_signup.inviter_id) then
    return jsonb_build_object('status', 'expired');
  end if;
  if not public._referral_member_ready(v_signup.inviter_id) then
    return jsonb_build_object('status', 'unavailable');
  end if;
  -- 모든 발급 경로에서 같은 순서로 잠금: 한 쪽만 지급되거나 수량을 초과하지 않게 한다.
  perform 1 from public.coupons where campaign_key in ('signup_referral_inviter', 'signup_referral_friend') order by id for update;
  select * into v_inviter from public.coupons where campaign_key = 'signup_referral_inviter';
  select * into v_friend from public.coupons where campaign_key = 'signup_referral_friend';
  if v_inviter.id is null or v_friend.id is null
    or not v_inviter.is_active or not v_friend.is_active
    or v_inviter.valid_from > now() or v_friend.valid_from > now()
    or v_inviter.valid_until <= now() or v_friend.valid_until <= now()
    or v_inviter.issued_count >= v_inviter.total_quantity or v_friend.issued_count >= v_friend.total_quantity then
    return jsonb_build_object('status', 'unavailable');
  end if;
  if v_enabled then
    if exists(select 1 from public.member_signup_benefit_claims
      where (phone_fingerprint=public._member_phone_fingerprint(v_phone) and coupon_id=v_friend.id)
        or (phone_fingerprint=public._member_phone_fingerprint(v_inviter_phone) and coupon_id=v_inviter.id)) then
      return jsonb_build_object('status','expired');
    end if;
    insert into public.member_signup_benefit_claims(phone_fingerprint,coupon_id,user_id)
      values(public._member_phone_fingerprint(v_phone),v_friend.id,p_user_id),
        (public._member_phone_fingerprint(v_inviter_phone),v_inviter.id,v_signup.inviter_id);
  end if;
  insert into public.member_coupons(coupon_id, user_id, issued_at, expires_at)
    values(v_inviter.id, v_signup.inviter_id, now(), public.compute_coupon_member_expiry(v_inviter.valid_days, v_inviter.valid_until))
    returning id into v_inviter_coupon;
  insert into public.member_coupons(coupon_id, user_id, issued_at, expires_at)
    values(v_friend.id, p_user_id, now(), public.compute_coupon_member_expiry(v_friend.valid_days, v_friend.valid_until))
    returning id into v_friend_coupon;
  update public.coupons set issued_count = issued_count + 1 where id in (v_inviter.id, v_friend.id);
  update public.member_referral_signups set rewarded_at = now(), inviter_coupon_id = v_inviter_coupon,
    invitee_coupon_id = v_friend_coupon where invitee_id = p_user_id;
  return jsonb_build_object('status', 'rewarded');
end;
$function$;

select pg_notify('pgrst','reload schema');
commit;
