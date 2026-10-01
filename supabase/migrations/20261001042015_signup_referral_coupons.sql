-- 친구 가입 완료 시 양쪽 4,000원 쿠폰을 같은 트랜잭션에서 지급한다.
-- 기존 가입/결제 RPC는 바꾸지 않고 새 가입자의 초대 연결만 별도로 기록한다.
begin;

insert into public.coupons (
  title, description, discount_type, discount_value, min_order_amount,
  valid_days, usage_limit_per_user, issuance_type, campaign_key
)
values
  ('친구 초대 감사 4,000원 할인', '초대한 친구의 가입 완료 시 지급됩니다.', 'fixed', 4000, 30000, 30, null, 'admin_assigned', 'signup_referral_inviter'),
  ('친구 초대 가입 4,000원 할인', '친구의 초대 링크로 가입 완료 시 지급됩니다.', 'fixed', 4000, 30000, 30, 1, 'admin_assigned', 'signup_referral_friend');

create table public.member_referral_codes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);
create table public.member_referral_signups (
  invitee_id uuid primary key references auth.users(id) on delete cascade,
  inviter_id uuid references auth.users(id) on delete set null,
  referral_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  rewarded_at timestamptz,
  inviter_coupon_id bigint references public.member_coupons(id) on delete restrict,
  invitee_coupon_id bigint references public.member_coupons(id) on delete restrict,
  check (inviter_id is null or inviter_id <> invitee_id),
  check ((rewarded_at is null and inviter_coupon_id is null and invitee_coupon_id is null)
    or (rewarded_at is not null and inviter_coupon_id is not null and invitee_coupon_id is not null))
);
create index member_referral_signups_inviter_idx on public.member_referral_signups(inviter_id);
alter table public.member_referral_codes enable row level security;
alter table public.member_referral_signups enable row level security;
-- 명시적으로 RPC만 허용. 초대자에게 친구의 계정/구매 정보는 공개하지 않는다.
revoke all on public.member_referral_codes, public.member_referral_signups from public, anon, authenticated;

create function public.get_signup_referral_offer(p_code text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'active', count(*) = 2 and bool_and(c.is_active and (c.valid_from is null or c.valid_from <= now())
      and (c.valid_until is null or c.valid_until > now()) and (c.total_quantity is null or c.issued_count < c.total_quantity)),
    'amount', 4000, 'min_order_amount', 30000, 'valid_days', min(c.valid_days),
    'code_valid', exists (
      select 1 from public.member_referral_codes r join public.member_profiles m on m.user_id = r.user_id
      where r.code = p_code and not coalesce(m.is_blocked, false) and m.withdrawal_requested_at is null
        and m.personal_data_erased_at is null and m.terms_agreed_at is not null and m.email_verified_at is not null
        and not exists (select 1 from public.member_referral_signups s where s.invitee_id = r.user_id and s.completed_at is null)
    )
  ) from public.coupons c where c.campaign_key in ('signup_referral_inviter', 'signup_referral_friend');
$$;

create function public.get_my_signup_referral()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_code text;
begin
  if v_user is null then raise exception '로그인이 필요합니다.'; end if;
  perform public.assert_member_not_blocked();
  if not exists (select 1 from public.member_profiles where user_id = v_user
    and terms_agreed_at is not null and email_verified_at is not null
    and withdrawal_requested_at is null and personal_data_erased_at is null)
    or exists (select 1 from public.member_referral_signups where invitee_id = v_user and completed_at is null) then
    raise exception '회원가입을 먼저 완료해 주세요.';
  end if;
  insert into public.member_referral_codes(user_id) values(v_user) on conflict (user_id) do nothing;
  select code into v_code from public.member_referral_codes where user_id = v_user;
  return jsonb_build_object('code', v_code,
    'reward_count', (select count(*) from public.member_referral_signups where inviter_id = v_user and rewarded_at is not null),
    'received_reward', exists (select 1 from public.member_referral_signups where invitee_id = v_user and rewarded_at is not null));
end;
$$;

create function public.attach_signup_referral(p_code text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_signup public.member_referral_signups%rowtype; v_inviter uuid;
begin
  if v_user is null then raise exception '로그인이 필요합니다.'; end if;
  perform public.assert_member_not_blocked();
  select * into v_signup from public.member_referral_signups where invitee_id = v_user for update;
  if not found then raise exception '초대 혜택은 신규 가입 시 받을 수 있습니다.'; end if;
  -- 응답 유실 후 같은 요청 재시도는 안전하게 성공한다. 다른 초대자로 변경할 수 없다.
  if v_signup.referral_code = p_code then return; end if;
  if v_signup.completed_at is not null or v_signup.referral_code is not null then
    raise exception '이미 가입을 완료했거나 다른 초대 링크가 적용되었습니다.';
  end if;
  if not coalesce((public.get_signup_referral_offer(p_code)->>'active')::boolean, false)
    or not coalesce((public.get_signup_referral_offer(p_code)->>'code_valid')::boolean, false) then
    raise exception '사용할 수 없는 초대 링크입니다.';
  end if;
  select user_id into v_inviter from public.member_referral_codes where code = p_code;
  if v_inviter = v_user then raise exception '본인의 초대 링크는 사용할 수 없습니다.'; end if;
  update public.member_referral_signups set inviter_id = v_inviter, referral_code = p_code where invitee_id = v_user;
end;
$$;

create function public._complete_signup_referral(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_signup public.member_referral_signups%rowtype;
  v_auth auth.users%rowtype;
  v_inviter public.coupons%rowtype;
  v_friend public.coupons%rowtype;
  v_inviter_coupon bigint; v_friend_coupon bigint;
begin
  select * into v_signup from public.member_referral_signups where invitee_id = p_user_id for update;
  if not found then return jsonb_build_object('status', 'not_eligible'); end if;
  if v_signup.rewarded_at is not null then return jsonb_build_object('status', 'rewarded'); end if;
  select * into v_auth from auth.users where id = p_user_id;
  if not exists (select 1 from public.member_profiles where user_id = p_user_id
      and terms_agreed_at is not null and privacy_agreed_at is not null
      and not coalesce(is_blocked, false) and withdrawal_requested_at is null and personal_data_erased_at is null)
    or v_auth.email_confirmed_at is null then
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
$$;

create function public.complete_signup_referral()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  perform public.assert_member_not_blocked();
  return public._complete_signup_referral(auth.uid());
end;
$$;

create function public.track_signup_referral_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_user uuid;
begin
  if tg_table_schema = 'auth' then
    v_user := new.id;
    if tg_op = 'INSERT' then
      insert into public.member_referral_signups(invitee_id) values(v_user) on conflict do nothing;
    end if;
  else v_user := new.user_id;
  end if;
  -- 쿠폰 처리 장애가 기존 회원가입을 중단시키지 않는다. pending 원장은 RPC로 재시도 가능.
  begin
    perform public._complete_signup_referral(v_user);
  exception when others then
    raise warning 'signup referral completion deferred: %', SQLSTATE;
  end;
  return new;
end;
$$;
create trigger zz_track_signup_referral_auth after insert or update on auth.users
  for each row execute function public.track_signup_referral_completion();
create trigger zz_track_signup_referral_profile after insert or update on public.member_profiles
  for each row execute function public.track_signup_referral_completion();

revoke all on function public.get_signup_referral_offer(text), public.get_my_signup_referral(),
  public.attach_signup_referral(text), public.complete_signup_referral(), public._complete_signup_referral(uuid),
  public.track_signup_referral_completion() from public, anon, authenticated;
grant execute on function public.get_signup_referral_offer(text) to anon, authenticated;
grant execute on function public.get_my_signup_referral(), public.attach_signup_referral(text), public.complete_signup_referral() to authenticated;
select pg_notify('pgrst', 'reload schema');
commit;
