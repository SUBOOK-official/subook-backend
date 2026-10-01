-- 번호 인증 이후에만 양쪽 쿠폰 동시 지급. 통합/재가입으로 초대 권리가 생기지 않는다.
begin;
create function public._referral_inviter_used(p_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.member_referral_signups s where s.rewarded_at is not null
    and (s.inviter_id=p_user_id or s.inviter_id in(select source_user_id from public.member_account_merges where target_user_id=p_user_id)));
$$;
create function public._referral_member_ready(p_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.member_profiles m where user_id=p_user_id
    and terms_agreed_at is not null and privacy_agreed_at is not null and not coalesce(is_blocked,false)
    and withdrawal_requested_at is null and personal_data_erased_at is null
    and not exists(select 1 from public.member_account_merges where source_user_id=p_user_id)
    and (case when (select enabled from public.member_identity_policy where singleton)
      then exists(select 1 from public.member_phone_identities where user_id=p_user_id)
      else email_verified_at is not null end));
$$;
revoke all on function public._referral_inviter_used(uuid),public._referral_member_ready(uuid) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.get_signup_referral_offer(p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'active', count(*) = 2 and bool_and(c.is_active and (c.valid_from is null or c.valid_from <= now())
      and (c.valid_until is null or c.valid_until > now()) and (c.total_quantity is null or c.issued_count < c.total_quantity)),
    'amount', 4000, 'min_order_amount', 30000, 'valid_days', min(c.valid_days),
    'code_expired', exists (
      select 1 from public.member_referral_codes r
      where r.code=p_code and (public._referral_inviter_used(r.user_id)
        or exists(select 1 from public.member_account_merges where source_user_id=r.user_id))
    ),
    'code_valid', exists (
      select 1 from public.member_referral_codes r join public.member_profiles m on m.user_id = r.user_id
      where r.code = p_code
        and not public._referral_inviter_used(r.user_id)
        and not coalesce(m.is_blocked, false) and m.withdrawal_requested_at is null
        and m.personal_data_erased_at is null and public._referral_member_ready(r.user_id)
        and not exists (select 1 from public.member_referral_signups s where s.invitee_id = r.user_id and s.completed_at is null)
    )
  ) from public.coupons c where c.campaign_key in ('signup_referral_inviter', 'signup_referral_friend');
$function$;

CREATE OR REPLACE FUNCTION public.get_my_signup_referral()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid := auth.uid(); v_code text;
begin
  if v_user is null then raise exception '로그인이 필요합니다.'; end if;
  perform public.assert_member_not_blocked();
  if not exists (select 1 from public.member_profiles where user_id = v_user
    and public._referral_member_ready(v_user)
    and withdrawal_requested_at is null and personal_data_erased_at is null)
    or exists (select 1 from public.member_referral_signups where invitee_id = v_user and completed_at is null) then
    raise exception '회원가입을 먼저 완료해 주세요.';
  end if;
  insert into public.member_referral_codes(user_id) values(v_user) on conflict (user_id) do nothing;
  select code into v_code from public.member_referral_codes where user_id = v_user;
  return jsonb_build_object('code', v_code,
    'can_invite', not public._referral_inviter_used(v_user),
    'reward_count', (select count(*) from public.member_referral_signups where inviter_id = v_user and rewarded_at is not null),
    'received_reward', exists (select 1 from public.member_referral_signups where invitee_id = v_user and rewarded_at is not null));
end;
$function$;

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
    or (not v_enabled and v_auth.email_confirmed_at is null) then
    return jsonb_build_object('status', 'pending');
  end if;
  -- 이메일 OTP는 인증 시 임시 계정이 생성된다. 비밀번호/명시 동의 저장까지 기다린다.
  if coalesce(v_auth.raw_app_meta_data->>'provider', 'email') = 'email'
    and (coalesce(v_auth.encrypted_password, '') = '' or nullif(v_auth.raw_user_meta_data->>'terms_agreed_at', '') is null
      or nullif(v_auth.raw_user_meta_data->>'privacy_agreed_at', '') is null) then
    return jsonb_build_object('status', 'pending');
  end if;
  update public.member_referral_signups set completed_at = coalesce(completed_at, now()) where invitee_id = p_user_id;
  if v_signup.inviter_id is null then return jsonb_build_object('status', 'no_referral'); end if;
  -- 같은 초대 링크로 가입을 동시에 완료해도 한 쌍만 받는다.
  perform 1 from public.member_referral_codes where user_id = v_signup.inviter_id for update;
  if public._referral_inviter_used(v_signup.inviter_id) then
    return jsonb_build_object('status', 'expired');
  end if;
  if not exists (select 1 from public.member_profiles where user_id = v_signup.inviter_id
    and not coalesce(is_blocked, false) and withdrawal_requested_at is null and personal_data_erased_at is null) then
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
