-- 휴대폰 소유 확인 뒤에만 기존 계정의 마스킹 이메일/실제 로그인 수단을 안내한다.
-- 데이터/번호 소유권은 변경하지 않는다. 내부 조회는 직접 RPC 접근 금지.
-- 롤백: get_my_member_identity는 20261001104338, verify_signup_phone_challenge는 20261001091226 정의 복원.
begin;
create function public._member_existing_phone_accounts(p_phone text,p_exclude_user_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  with owner as (
    select user_id from public.member_phone_identities where phone=p_phone
  ), candidates as (
    select u.id,u.email,u.encrypted_password,u.created_at
    from auth.users u join public.member_profiles m on m.user_id=u.id
    where u.id is distinct from p_exclude_user_id and u.deleted_at is null
      and m.personal_data_erased_at is null and m.withdrawal_requested_at is null and not coalesce(m.is_blocked,false)
      and not exists(select 1 from public.member_account_merges x where x.source_user_id=u.id)
      and (exists(select 1 from owner where user_id=u.id)
        or (not exists(select 1 from owner)
          and exists(select 1 from public.member_legacy_phone_accounts l where l.user_id=u.id and l.phone=p_phone)
          and not exists(select 1 from public.member_phone_identities i where i.user_id=u.id and i.phone<>p_phone)))
    order by u.created_at,u.id limit 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'email_hint',case when c.email like '%@%' and c.email not like '%@oauth.subook.local' then
      case when length(split_part(c.email,'@',1))=1 then '*'
        else left(split_part(c.email,'@',1),least(2,length(split_part(c.email,'@',1))-1))||'***' end
        ||'@'||split_part(c.email,'@',2) else null end,
    'providers',case when c.email is null or c.email not like '%@%' or c.email like '%@oauth.subook.local' then '[]'::jsonb
      else (select coalesce(jsonb_agg(p.provider order by p.provider),'[]'::jsonb) from (
        select distinct i.provider from auth.identities i where i.user_id=c.id and i.provider in('kakao','google','email')
        union select 'email' where nullif(c.encrypted_password,'') is not null
      ) p) end
  ) order by c.created_at,c.id),'[]'::jsonb) from candidates c;
$$;
revoke all on function public._member_existing_phone_accounts(text,uuid) from public,anon,authenticated;

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
    'is_legacy_account',v_legacy,'can_merge',v_can_merge,
    'existing_accounts',case when v_status='existing_account' then public._member_existing_phone_accounts(v_proof,auth.uid()) else '[]'::jsonb end);
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
    return jsonb_build_object('success',true,'status','existing_account',
      'existing_accounts',public._member_existing_phone_accounts(v_row.phone,null));
  end if;
  return jsonb_build_object('success',true,'status','verified','phone',v_row.phone);
end;
$$;
notify pgrst,'reload schema';
commit;
