-- 번호 충돌 안내와 실제 통합 시작이 같은 후보/보호 조건을 사용한다.
-- 회원 데이터, 관리자 권한, 기존 통합/자산 이관 함수는 변경하지 않는다.
-- 롤백: 20261001091226의 _claim_member_phone/get_my_member_identity/start_member_account_merge 정의 복원.
begin;

create function public._member_phone_merge_candidates(p_user_id uuid,p_phone text) returns uuid[]
language plpgsql stable security definer set search_path='' as $$
declare v_candidates uuid[];
begin
  if p_user_id is null or p_phone is null
    or not coalesce((select merge_enabled from public.member_identity_policy where singleton),false) then
    return '{}'::uuid[];
  end if;
  select array_agg(m.user_id order by m.user_id) into v_candidates from public.member_profiles m
  where public._member_is_legacy_account(m.user_id)
    and (m.user_id=p_user_id
      or exists(select 1 from public.member_legacy_phone_accounts l where l.user_id=m.user_id and l.phone=p_phone)
      or exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone=p_phone))
    and not exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone<>p_phone)
    and not coalesce(m.is_blocked,false) and m.withdrawal_requested_at is null and m.personal_data_erased_at is null
    and not exists(select 1 from public.admin_users a where lower(a.email)=lower(m.email))
    and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id);
  -- 현재 계정과 다른 기존 계정이 모두 대상이어야 한다.
  if not coalesce(p_user_id=any(v_candidates),false) or coalesce(cardinality(v_candidates),0)<2 then
    return '{}'::uuid[];
  end if;
  -- 이미 인증된 번호 소유자가 제외되면 마지막 통합 단계에서도 완료할 수 없다.
  if exists(select 1 from public.member_phone_identities i where i.phone=p_phone and not i.user_id=any(v_candidates)) then
    return '{}'::uuid[];
  end if;
  return v_candidates;
end;
$$;
revoke all on function public._member_phone_merge_candidates(uuid,text) from public,anon,authenticated;

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
  v_conflict:=not exists(select 1 from public.member_phone_identities where user_id=p_user_id and phone=v_phone)
    and public._member_phone_conflicts(p_user_id,v_phone);
  if v_conflict then
    if cardinality(public._member_phone_merge_candidates(p_user_id,v_phone))>=2 then
      return jsonb_build_object('success',true,'status','merge_required','phone',v_phone);
    end if;
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
declare v_phone text; v_proof text; v_target uuid; v_legacy boolean; v_status text; v_can_merge boolean:=false;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select target_user_id into v_target from public.member_account_merges where source_user_id=auth.uid();
  select phone into v_phone from public.member_phone_identities where user_id=auth.uid();
  select phone into v_proof from public.member_phone_proofs where user_id=auth.uid() and expires_at>now();
  v_legacy:=public._member_is_legacy_account(auth.uid());
  v_status:=case when v_target is not null then 'merged' when v_phone is not null then 'verified' else 'unverified' end;
  if v_status='unverified' and v_proof is not null and public._member_phone_conflicts(auth.uid(),v_proof) then
    v_can_merge:=cardinality(public._member_phone_merge_candidates(auth.uid(),v_proof))>=2;
    if not v_can_merge then v_status:='existing_account'; end if;
  end if;
  return public.get_member_identity_policy()||jsonb_build_object('status',v_status,'phone',v_phone,
    'is_legacy_account',v_legacy,'can_merge',v_can_merge);
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
  v_candidates:=public._member_phone_merge_candidates(auth.uid(),v_proof.phone);
  if cardinality(v_candidates)<2 then raise exception '이 전화번호로 가입된 계정이 있습니다. 기존 계정으로 로그인해 주세요.'; end if;
  insert into public.member_merge_requests(requester_id,phone,secret_hash,verified_users,candidate_users,expires_at)
    values(auth.uid(),v_proof.phone,encode(extensions.digest(v_secret,'sha256'),'hex'),array[auth.uid()],v_candidates,v_proof.expires_at)
    returning * into v_request;
  return public._member_merge_view(v_request)||jsonb_build_object('secret',v_secret);
end;
$$;
notify pgrst,'reload schema';
commit;
