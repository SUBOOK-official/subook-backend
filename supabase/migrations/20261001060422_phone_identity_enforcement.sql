-- 전화 인증 정책. 기본 OFF; SMS/Auth 준비 및 통합 검증 후 별도 활성화한다.
-- 롤백: 정책 false, authenticator의 pgrst.db_pre_request 원래 설정 복원.
begin;
alter table public.member_identity_policy add column activated_at timestamptz;

create function public.enforce_member_identity_request() returns void
language plpgsql security definer set search_path='' as $$
declare v_path text:=ltrim(coalesce(current_setting('request.path',true),''),'/');
begin
  if auth.uid() is null or auth.role()='service_role' then return; end if;
  -- 운영자 콘솔은 회원 전화 정책과 독립적이다.
  if public.is_admin_user() then return; end if;
  if v_path in ('rpc/get_member_identity_policy','rpc/get_my_member_identity','rpc/get_current_auth_account_role',
    'rpc/is_admin_user','rpc/verify_phone_otp','rpc/start_member_account_merge','rpc/get_member_account_merge',
    'rpc/prove_member_account_merge','rpc/complete_member_account_merge','rpc/attach_signup_referral','rpc/get_signup_referral_offer') then return; end if;
  if public.member_identity_is_ready() then return; end if;
  raise sqlstate 'PT403' using message='휴대폰 인증 또는 계정 통합을 완료해 주세요.';
end;
$$;
revoke all on function public.enforce_member_identity_request() from public;
grant execute on function public.enforce_member_identity_request() to anon,authenticated,service_role;
-- 실제 pre-request 등록은 운영 전환 절차에서 기존 설정을 확인하고 실행한다.

create function public.reserve_member_auth_sms_hook(p_phone text,p_hook_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_result jsonb; v_existing public.member_auth_sms_attempts%rowtype;
begin
  if not (select phone_signup_enabled from public.member_identity_policy where singleton) then
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
create function public.complete_member_auth_sms_hook(p_hook_id text) returns void
language sql security definer set search_path='' as $$
  update public.member_auth_sms_attempts set sent_at=now() where hook_id=p_hook_id and sent_at is null;
$$;
revoke all on function public.reserve_member_auth_sms_hook(text,text),public.complete_member_auth_sms_hook(text) from public,anon,authenticated;
grant execute on function public.reserve_member_auth_sms_hook(text,text),public.complete_member_auth_sms_hook(text) to service_role;

-- 신규/기존 OTP 모두 DB 잠금 하에 사용자/번호별 발송 한도를 예약한다.
create function public.reserve_member_phone_otp(p_user_id uuid,p_phone text,p_code_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_phone text:=public.normalize_member_phone(p_phone); v_result jsonb;
begin
  if not exists(select 1 from public.member_profiles where user_id=p_user_id and not coalesce(is_blocked,false)
    and withdrawal_requested_at is null and personal_data_erased_at is null)
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
    next_terms_agreed_at := coalesce(new.created_at, now());
  end if;

  if v_meta_privacy_text is not null then
    next_privacy_agreed_at := v_meta_privacy_text::timestamptz;
  elsif is_oauth_user or new.raw_app_meta_data->>'provider'='phone' then
    next_privacy_agreed_at := null;
  else
    next_privacy_agreed_at := coalesce(new.created_at, now());
  end if;

  next_marketing_agreed_at := case
    when not next_marketing_opt_in then null
    when v_meta_marketing_text is not null then v_meta_marketing_text::timestamptz
    when is_oauth_user or new.raw_app_meta_data->>'provider'='phone' then null
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
CREATE OR REPLACE FUNCTION public.assert_member_not_blocked()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_blocked boolean;
  v_reason text;
begin
  if auth.uid() is null then
    return;  -- 인증 체크는 호출자가 별도 수행
  end if;

  if exists(select 1 from public.member_account_merges where source_user_id=auth.uid()) then
    raise exception '통합된 계정입니다. 대표 계정으로 로그인해 주세요.';
  end if;
  if (select enabled from public.member_identity_policy where singleton)
    and not exists(select 1 from public.member_phone_identities where user_id=auth.uid()) then
    raise exception '휴대폰 인증을 먼저 완료해 주세요.';
  end if;
  select coalesce(is_blocked, false), block_reason
  into v_blocked, v_reason
  from public.member_profiles
  where user_id = auth.uid();

  if v_blocked then
    raise exception '계정이 차단되어 해당 작업을 수행할 수 없습니다. %', coalesce('사유: ' || v_reason, '');
  end if;
end;
$function$
;

create function public._issue_verified_signup_coupons(p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_coupon public.coupons%rowtype; v_phone text; v_enabled boolean; v_activated timestamptz;
begin
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
create or replace function public.issue_signup_coupons_for_new_member() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and not (select enabled from public.member_identity_policy where singleton) then return new; end if;
  perform public._issue_verified_signup_coupons(new.user_id); return new;
exception when others then return new; end;
$$;
create trigger issue_signup_after_phone_and_terms after update of verified_phone,terms_agreed_at,privacy_agreed_at on public.member_profiles
  for each row when(new.terms_agreed_at is not null and new.privacy_agreed_at is not null and new.verified_phone is not null)
  execute function public.issue_signup_coupons_for_new_member();
revoke all on function public._issue_verified_signup_coupons(uuid) from public,anon,authenticated;
-- 이전에 인증을 마친 회원의 발급 이력도 같은 번호의 혜택 원장으로 승계한다.
insert into public.member_signup_benefit_claims(phone_fingerprint,coupon_id,user_id,claimed_at)
select public._member_phone_fingerprint(i.phone),mc.coupon_id,mc.user_id,mc.issued_at
from public.member_phone_identities i join public.member_coupons mc on mc.user_id=i.user_id
join public.coupons c on c.id=mc.coupon_id
where c.issue_on_signup or c.campaign_key in ('signup_referral_inviter','signup_referral_friend')
on conflict do nothing;

-- Realtime/직접 테이블 접근에도 통합된 계정의 기존 토큰을 차단한다.
do $$ declare t text; begin
  foreach t in array array['orders','order_items','cart_items','wishlist_items','member_coupons','point_lots','point_transactions',
    'member_shipping_addresses','member_settlement_accounts','member_notifications','pickup_requests','pickup_items',
    'settlements','shipments','reviews','restock_notifications','restock_keyword_subscriptions'] loop
    execute format('create policy member_phone_identity_required on public.%I as restrictive for all to authenticated using (public.is_admin_user() or public.member_identity_is_ready()) with check (public.is_admin_user() or public.member_identity_is_ready())',t);
  end loop;
end $$;
select pg_notify('pgrst','reload schema');
create function public.enforce_profile_identity_phone() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_phone text;
begin
  if new.personal_data_erased_at is not null then return new; end if;
  if (select enabled from public.member_identity_policy where singleton) then
    select phone into v_phone from public.member_phone_identities where user_id=new.user_id;
    if v_phone is not null then new.phone:=v_phone; end if;
  end if;
  return new;
end;
$$;
create trigger enforce_profile_identity_phone before insert or update on public.member_profiles
  for each row execute function public.enforce_profile_identity_phone();
revoke all on function public.enforce_profile_identity_phone() from public,anon,authenticated;

create or replace function public._link_member_legacy_shipments() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if nullif(btrim(new.phone),'') is null or nullif(btrim(new.name),'') is null then return new; end if;
  if exists(select 1 from public.member_account_merges where source_user_id=new.user_id) then return new; end if;
  if (select enabled from public.member_identity_policy where singleton) and not exists(
    select 1 from public.member_phone_identities where user_id=new.user_id and phone=public.normalize_member_phone(new.phone)) then return new; end if;
  update public.shipments s set user_id=new.user_id where s.user_id is null and s.seller_name=new.name
    and public.normalize_member_phone(s.seller_phone)=public.normalize_member_phone(new.phone)
    and not exists(select 1 from public.member_profiles m where m.user_id<>new.user_id and m.name=s.seller_name
      and public.normalize_member_phone(m.phone)=public.normalize_member_phone(s.seller_phone)
      and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id));
  return new;
end;
$$;
commit;
