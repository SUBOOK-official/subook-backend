-- 신규 중복 가입은 기존 계정 로그인으로 안내. 전환 전 계정만 대표 선택 통합 가능.
-- 기존 회원/자산은 수정하지 않는다. 롤백 시 이전 함수 정의 복원, 원장은 보존.
begin;
create function public._member_is_legacy_account(p_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users u cross join public.member_identity_policy p
    where u.id=p_user_id and u.created_at<p.activated_at);
$$;
create function public._member_phone_conflicts(p_user_id uuid,p_phone text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.member_phone_identities where phone=p_phone and user_id is distinct from p_user_id)
    or exists(select 1 from public.member_profiles m join public.member_legacy_phone_accounts l on l.user_id=m.user_id
      where m.user_id is distinct from p_user_id and l.phone=p_phone and m.personal_data_erased_at is null
        and not exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone<>p_phone)
        and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id));
$$;
revoke all on function public._member_is_legacy_account(uuid),public._member_phone_conflicts(uuid,text) from public,anon,authenticated;

create or replace function public._claim_member_phone(p_user_id uuid,p_phone text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_phone text:=public.normalize_member_phone(p_phone); v_conflict boolean;
begin
  if v_phone !~ '^010[0-9]{8}$' then raise exception '국내 휴대폰 번호를 확인해 주세요.'; end if;
  if exists(select 1 from public.member_account_merges where source_user_id=p_user_id) then
    return jsonb_build_object('success',false,'status','merged','error','통합된 계정입니다. 대표 계정으로 로그인해 주세요.');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('member-phone:'||v_phone,0));
  if exists(select 1 from public.member_phone_identities where user_id=p_user_id and phone<>v_phone) then
    return jsonb_build_object('success',false,'status','phone_change_required','error','이미 인증된 번호가 있습니다. 번호 변경은 고객센터로 문의해 주세요.');
  end if;
  insert into public.member_phone_proofs(user_id,phone,verified_at,expires_at)
    values(p_user_id,v_phone,now(),now()+interval '20 minutes')
    on conflict(user_id) do update set phone=excluded.phone,verified_at=excluded.verified_at,expires_at=excluded.expires_at;
  -- 본인에게 이미 귀속된 번호는 같은 계정의 재로그인이다.
  v_conflict:=not exists(select 1 from public.member_phone_identities where user_id=p_user_id and phone=v_phone)
    and public._member_phone_conflicts(p_user_id,v_phone);
  if v_conflict then
    if public._member_is_legacy_account(p_user_id) then
      return jsonb_build_object('success',true,'status','merge_required','phone',v_phone);
    end if;
    -- 신규 OAuth는 인증 세션만 보유한다. 중복 번호로 회원 프로필을 생성하지 않는다.
    return jsonb_build_object('success',true,'status','existing_account');
  end if;
  insert into public.member_phone_identities(phone,user_id) values(v_phone,p_user_id)
    on conflict(phone) do update set verified_at=now() where member_phone_identities.user_id=p_user_id;
  perform public.ensure_verified_member_profile(p_user_id);
  update public.member_profiles set verified_phone=v_phone,phone=v_phone,phone_verified_at=now(),updated_at=now() where user_id=p_user_id;
  return jsonb_build_object('success',true,'status','verified','phone',v_phone);
end;
$$;

create or replace function public.get_my_member_identity() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_phone text; v_proof text; v_target uuid; v_legacy boolean; v_status text;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select target_user_id into v_target from public.member_account_merges where source_user_id=auth.uid();
  select phone into v_phone from public.member_phone_identities where user_id=auth.uid();
  select phone into v_proof from public.member_phone_proofs where user_id=auth.uid() and expires_at>now();
  v_legacy:=public._member_is_legacy_account(auth.uid());
  v_status:=case when v_target is not null then 'merged' when v_phone is not null then 'verified'
    when not v_legacy and v_proof is not null and public._member_phone_conflicts(auth.uid(),v_proof) then 'existing_account' else 'unverified' end;
  return public.get_member_identity_policy()||jsonb_build_object('status',v_status,'phone',v_phone,
    'is_legacy_account',v_legacy,'can_merge',v_legacy and v_proof is not null and v_target is null);
end;
$$;
create or replace function public.verify_signup_phone_challenge(p_id uuid,p_secret_hash text,p_code_hash text) returns jsonb
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
  if public._member_phone_conflicts(null,v_row.phone) then
    return jsonb_build_object('success',true,'status','existing_account');
  end if;
  return jsonb_build_object('success',true,'status','verified','phone',v_row.phone);
end;
$$;

create or replace function public.before_member_user_created(event jsonb) returns jsonb
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
  if exists(select 1 from public.member_signup_phone_challenges c where c.id=v_id::uuid and public._member_phone_conflicts(null,c.phone)) then
    return jsonb_build_object('error',jsonb_build_object('http_code',400,'message','이 전화번호로 가입된 계정이 있습니다. 기존 계정으로 로그인해 주세요.'));
  end if;
  return '{}'::jsonb;
end;
$$;

create or replace function public.claim_signup_phone_challenge() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_id text:=new.raw_user_meta_data->>'signup_phone_id'; v_secret text:=new.raw_user_meta_data->>'signup_phone_secret'; v_phone text;
begin
  if v_id is null or v_id !~ '^[a-f0-9-]{36}$' or v_secret is null then return new; end if;
  update public.member_signup_phone_challenges set claimed_user_id=new.id,claimed_at=now()
    where id=v_id::uuid and email=lower(new.email) and secret_hash=encode(extensions.digest(v_secret,'sha256'),'hex')
      and verified_at is not null and expires_at>now() and claimed_at is null returning phone into v_phone;
  if v_phone is null then raise exception '휴대폰 인증을 다시 진행해 주세요.'; end if;
  if public._claim_member_phone(new.id,v_phone)->>'status'<>'verified' then
    raise exception '이 전화번호로 가입된 계정이 있습니다. 기존 계정으로 로그인해 주세요.';
  end if;
  return new;
end;
$$;

create or replace function public.start_member_account_merge() returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_proof public.member_phone_proofs%rowtype; v_request public.member_merge_requests%rowtype;
  v_secret text:=encode(extensions.gen_random_bytes(32),'hex'); v_candidates uuid[];
begin
  if auth.uid() is null or not (select merge_enabled from public.member_identity_policy where singleton) then raise exception '계정 통합을 준비 중입니다.'; end if;
  if not public._member_is_legacy_account(auth.uid()) then raise exception '이 전화번호로 가입된 계정이 있습니다. 기존 계정으로 로그인해 주세요.'; end if;
  select * into v_proof from public.member_phone_proofs where user_id=auth.uid() and expires_at>now();
  if not found then raise exception '휴대폰을 다시 인증해 주세요.'; end if;
  if exists(select 1 from public.member_account_merges where source_user_id=auth.uid()) then raise exception '대표 계정으로 로그인해 주세요.'; end if;
  select array_agg(m.user_id order by m.user_id) into v_candidates from public.member_profiles m
  where public._member_is_legacy_account(m.user_id) and (m.user_id=auth.uid() or exists(select 1 from public.member_legacy_phone_accounts l where l.user_id=m.user_id and l.phone=v_proof.phone)
      or exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone=v_proof.phone))
    and not exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone<>v_proof.phone)
    and not coalesce(m.is_blocked,false) and m.withdrawal_requested_at is null and m.personal_data_erased_at is null
    and not exists(select 1 from public.admin_users a where lower(a.email)=lower(m.email))
    and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id);
  if not coalesce(auth.uid()=any(v_candidates),false) then raise exception '통합할 수 없는 계정입니다.'; end if;
  insert into public.member_merge_requests(requester_id,phone,secret_hash,verified_users,candidate_users,expires_at)
    values(auth.uid(),v_proof.phone,encode(extensions.digest(v_secret,'sha256'),'hex'),array[auth.uid()],v_candidates,v_proof.expires_at)
    returning * into v_request;
  return public._member_merge_view(v_request)||jsonb_build_object('secret',v_secret);
end;
$$;

create or replace function public._get_member_merge_request(p_id uuid,p_secret text) returns public.member_merge_requests
language plpgsql stable security definer set search_path='' as $$
declare r public.member_merge_requests%rowtype;
begin
  select * into r from public.member_merge_requests where id=p_id
    and secret_hash=encode(extensions.digest(coalesce(p_secret,''),'sha256'),'hex');
  if not found or auth.uid() is null or not auth.uid()=any(r.candidate_users) then raise exception '계정 통합 요청을 확인할 수 없습니다.'; end if;
  if r.completed_at is null and r.expires_at<=now() then raise exception '인증 시간이 만료되었습니다. 휴대폰 인증부터 다시 진행해 주세요.'; end if;
  if r.completed_at is null and exists(select 1 from unnest(r.candidate_users) candidate where not public._member_is_legacy_account(candidate)) then
    raise exception '신규 가입은 기존 계정으로 로그인해 주세요.';
  end if;
  return r;
end;
$$;
-- 번호 단독 계정 1개의 이메일 등록 복구에만 기존 Phone Auth를 허용한다.
create or replace function public.reserve_member_auth_sms_hook(p_phone text,p_hook_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_result jsonb; v_existing public.member_auth_sms_attempts%rowtype;
begin
  if not exists(select 1 from auth.users where public.normalize_member_phone(phone)=public.normalize_member_phone(p_phone) and phone_confirmed_at is not null and nullif(email,'') is null and raw_app_meta_data->>'provider'='phone') then
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

select pg_notify('pgrst','reload schema');
commit;
