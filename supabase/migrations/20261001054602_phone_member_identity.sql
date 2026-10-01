-- 휴대폰 소유 증명과 회원 식별자를 분리한다. 운영 전환은 검증 후 별도 활성화한다.
-- 롤백: member_identity_policy.enabled/phone_signup_enabled/merge_enabled를 false로.
-- 실제 통합 이력/번호 소유 원장은 되돌릴 때도 보존한다.
begin;
create table public.member_identity_policy (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  phone_signup_enabled boolean not null default false,
  merge_enabled boolean not null default false,
  phone_claim_key bytea not null default extensions.gen_random_bytes(32)
);
insert into public.member_identity_policy(singleton) values(true);
create table public.member_phone_identities (
  phone text primary key check(phone ~ '^010[0-9]{8}$'),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  verified_at timestamptz not null default now()
);
create table public.member_phone_proofs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text not null check(phone ~ '^010[0-9]{8}$'),
  verified_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '20 minutes'
);
-- 전환 이전 입력 번호만 통합 후보로 사용한다. 이후 metadata 조작으로 후보를 만들 수 없다.
create table public.member_legacy_phone_accounts (
  user_id uuid primary key references auth.users(id),
  phone text not null
);
create table public.member_account_merges (
  source_user_id uuid primary key references auth.users(id) on delete restrict,
  target_user_id uuid not null references auth.users(id) on delete restrict,
  merged_at timestamptz not null default now(),
  details jsonb not null default '{}',
  check(source_user_id<>target_user_id)
);
create table public.member_merge_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id),
  phone text not null,
  secret_hash text not null,
  verified_users uuid[] not null,
  expires_at timestamptz not null default now()+interval '20 minutes',
  completed_at timestamptz,
  target_user_id uuid references auth.users(id)
);
create table public.member_signup_benefit_claims (
  phone_fingerprint text not null,
  coupon_id bigint not null references public.coupons(id),
  user_id uuid not null references auth.users(id),
  claimed_at timestamptz not null default now(),
  primary key(phone_fingerprint,coupon_id)
);
create table public.member_auth_sms_attempts (
  id bigint generated always as identity primary key,
  phone text not null,
  requested_at timestamptz not null default now(),
  hook_id text unique,
  sent_at timestamptz
);
create index member_auth_sms_attempts_phone_time on public.member_auth_sms_attempts(phone,requested_at desc);
do $$ declare t text; begin
  foreach t in array array['member_identity_policy','member_phone_identities','member_phone_proofs',
    'member_account_merges','member_merge_requests','member_signup_benefit_claims','member_auth_sms_attempts','member_legacy_phone_accounts'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
  end loop;
end $$;

create function public.normalize_member_phone(p_phone text) returns text
language sql immutable set search_path='' as $$
  select case when regexp_replace(coalesce(p_phone,''),'[^0-9]','','g') like '8210%'
    then '0'||substr(regexp_replace(p_phone,'[^0-9]','','g'),3)
    else regexp_replace(coalesce(p_phone,''),'[^0-9]','','g') end;
$$;
insert into public.member_legacy_phone_accounts(user_id,phone)
select user_id,public.normalize_member_phone(case when phone_verified_at is not null
  and public.normalize_member_phone(verified_phone) ~ '^010[0-9]{8}$' then verified_phone else phone end)
from public.member_profiles
where public.normalize_member_phone(phone) ~ '^010[0-9]{8}$'
  or (phone_verified_at is not null and public.normalize_member_phone(verified_phone) ~ '^010[0-9]{8}$');
create function public.get_member_identity_policy() returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('enabled',enabled,'phone_signup_enabled',phone_signup_enabled,'merge_enabled',merge_enabled)
    from public.member_identity_policy where singleton;
$$;
create function public._member_phone_fingerprint(p_phone text) returns text
language sql stable security definer set search_path='' as $$
  select encode(extensions.hmac(convert_to(public.normalize_member_phone(p_phone),'UTF8'),phone_claim_key,'sha256'),'hex')
    from public.member_identity_policy where singleton;
$$;
revoke all on function public._member_phone_fingerprint(text) from public,anon,authenticated;
create function public.member_identity_is_ready() returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null
    and not exists(select 1 from public.member_account_merges where source_user_id=auth.uid())
    and (not (select enabled from public.member_identity_policy where singleton)
      or exists(select 1 from public.member_phone_identities where user_id=auth.uid()));
$$;
create function public.get_my_member_identity() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_phone text; v_target uuid;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select target_user_id into v_target from public.member_account_merges where source_user_id=auth.uid();
  select phone into v_phone from public.member_phone_identities where user_id=auth.uid();
  return public.get_member_identity_policy()||jsonb_build_object(
    'status',case when v_target is not null then 'merged' when v_phone is not null then 'verified' else 'unverified' end,
    'phone',v_phone,'can_merge',exists(select 1 from public.member_phone_proofs where user_id=auth.uid() and expires_at>now()));
end;
$$;

-- 서버에서 검증된 증명만 이 함수에 도달한다. 입력한 phone/metadata로 우회할 수 없다.
create function public._claim_member_phone(p_user_id uuid,p_phone text) returns jsonb
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
  update public.member_profiles set verified_phone=v_phone,phone=v_phone,phone_verified_at=now(),updated_at=now() where user_id=p_user_id;
  return jsonb_build_object('success',true,'status','verified','phone',v_phone);
end;
$$;

create function public.sync_confirmed_auth_phone() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_result jsonb;
begin
  if new.phone_confirmed_at is not null and public.normalize_member_phone(new.phone) ~ '^010[0-9]{8}$' then
    v_result:=public._claim_member_phone(new.id,new.phone);
    if v_result->>'status'='phone_change_required' then raise exception '인증 번호 변경은 고객센터로 문의해 주세요.'; end if;
  end if;
  return new;
end;
$$;
create trigger zy_sync_confirmed_auth_phone after insert or update of phone,phone_confirmed_at on auth.users
  for each row execute function public.sync_confirmed_auth_phone();

-- 단독으로 인증된 번호만 승계한다. 과거 인증 번호도 중복이면 재인증/대표 선택으로 해결한다.
-- 기존 인증 필드를 지우거나 특정 계정을 임의로 대표로 지정하지 않는다.
insert into public.member_phone_identities(phone,user_id,verified_at)
select phone,user_id,phone_verified_at from (
  select public.normalize_member_phone(verified_phone) phone,user_id,phone_verified_at,
    count(*) over(partition by public.normalize_member_phone(verified_phone)) as owners
  from public.member_profiles where phone_verified_at is not null
    and public.normalize_member_phone(verified_phone) ~ '^010[0-9]{8}$'
) verified where owners=1;

create or replace function public.verify_phone_otp(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_row public.phone_verification_codes%rowtype; v_result jsonb;
begin
  if v_user is null then raise exception '로그인이 필요합니다.'; end if;
  if exists(select 1 from public.member_profiles where user_id=v_user and
    (is_blocked or withdrawal_requested_at is not null or personal_data_erased_at is not null)) then
    raise exception '이용할 수 없는 계정입니다.';
  end if;
  select * into v_row from public.phone_verification_codes where user_id=v_user
    order by created_at desc,id desc limit 1 for update;
  if not found or v_row.verified_at is not null or v_row.expires_at<=now() then
    return jsonb_build_object('success',false,'error','인증번호를 다시 받아 주세요.');
  end if;
  if v_row.attempt_count>=5 then return jsonb_build_object('success',false,'error','시도 횟수를 초과했습니다. 인증번호를 다시 받아 주세요.'); end if;
  update public.phone_verification_codes set attempt_count=attempt_count+1 where id=v_row.id;
  if encode(extensions.digest(btrim(coalesce(p_code,''))||v_user::text,'sha256'),'hex')<>v_row.code_hash then
    -- 예외를 던지면 시도 횟수도 롤백되므로 정상 응답으로 실패를 전달한다.
    return jsonb_build_object('success',false,'error','인증번호가 일치하지 않습니다.','attempts_left',greatest(0,4-v_row.attempt_count));
  end if;
  update public.phone_verification_codes set verified_at=now() where id=v_row.id;
  v_result:=public._claim_member_phone(v_user,v_row.phone);
  return v_result;
end;
$$;

create function public.reserve_member_auth_sms(p_phone text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_phone text:=public.normalize_member_phone(p_phone);
begin
  if v_phone !~ '^010[0-9]{8}$' then return jsonb_build_object('success',false,'error','국내 휴대폰 번호를 확인해 주세요.'); end if;
  perform pg_advisory_xact_lock(hashtextextended('member-sms:'||v_phone,0));
  if exists(select 1 from public.member_auth_sms_attempts where phone=v_phone and requested_at>now()-interval '60 seconds') then
    return jsonb_build_object('success',false,'error','인증번호는 1분 후 다시 요청할 수 있습니다.');
  end if;
  if (select count(*) from public.member_auth_sms_attempts where phone=v_phone and requested_at>now()-interval '1 day')>=8 then
    return jsonb_build_object('success',false,'error','오늘 인증 요청 한도를 초과했습니다.');
  end if;
  insert into public.member_auth_sms_attempts(phone) values(v_phone);
  return jsonb_build_object('success',true);
end;
$$;

-- 인증된 번호는 사용자 UPDATE로 변조할 수 없게 한다(서버 RPC/트리거만 갱신).
create function public.guard_member_phone_fields() returns trigger
language plpgsql set search_path='' as $$
begin
  if current_user in ('authenticated','anon') and (
    (tg_op='INSERT' and (new.verified_phone is not null or new.phone_verified_at is not null)) or
    (tg_op='UPDATE' and (new.verified_phone is distinct from old.verified_phone or new.phone_verified_at is distinct from old.phone_verified_at))) then
    raise exception '인증된 번호는 휴대폰 인증으로만 변경할 수 있습니다.';
  end if;
  return new;
end;
$$;
create trigger guard_member_phone_fields before insert or update on public.member_profiles
  for each row execute function public.guard_member_phone_fields();

revoke all on function public._claim_member_phone(uuid,text),public.sync_confirmed_auth_phone(),
  public.reserve_member_auth_sms(text),public.get_my_member_identity(),public.get_member_identity_policy(),
  public.member_identity_is_ready(),public.guard_member_phone_fields() from public,anon,authenticated;
grant execute on function public.get_member_identity_policy() to anon,authenticated;
grant execute on function public.get_my_member_identity(),public.member_identity_is_ready() to authenticated;
grant execute on function public.reserve_member_auth_sms(text) to service_role;
select pg_notify('pgrst','reload schema');
commit;
