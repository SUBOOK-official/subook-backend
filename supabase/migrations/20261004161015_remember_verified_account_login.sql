-- 20분 소유 증명과 재로그인 안내를 분리한다. 안내는 인증/통합/번호 귀속 권한이 아니다.
-- 기존 proof 테이블의 RLS·직접 접근 금지·개인정보 파기 경로를 그대로 사용한다.
-- 롤백: get_my_member_identity와 _member_existing_phone_accounts를 20261001110924 정의로 복원.
-- 추가한 비공개 컬럼/함수/트리거는 보존해도 이전 동작에 영향이 없다. 기존 데이터 갱신 없음.
begin;

alter table public.member_phone_proofs add column login_hint_account_ids uuid[];

create function public._member_existing_phone_account_ids(p_phone text,p_exclude_user_id uuid) returns uuid[]
language sql stable security definer set search_path='' as $$
  with owner as (
    select user_id from public.member_phone_identities where phone=p_phone
  ), candidates as (
    select u.id,u.created_at
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
  select coalesce(array_agg(id order by created_at,id),'{}'::uuid[]) from candidates;
$$;

create function public._member_phone_login_hints(p_phone text,p_exclude_user_id uuid,p_account_ids uuid[]) returns jsonb
language sql stable security definer set search_path='' as $$
  -- 예전에 확인한 계정과 지금도 이 번호로 유효한 계정의 교집합만 안내한다.
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
  ) order by c.created_at,c.id),'[]'::jsonb)
  from auth.users c
  where c.id=any(p_account_ids)
    and c.id=any(public._member_existing_phone_account_ids(p_phone,p_exclude_user_id));
$$;

create or replace function public._member_existing_phone_accounts(p_phone text,p_exclude_user_id uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select public._member_phone_login_hints(p_phone,p_exclude_user_id,
    public._member_existing_phone_account_ids(p_phone,p_exclude_user_id));
$$;

create function public.remember_member_phone_login_hint() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- 이 테이블은 서버에서 실제 OTP/카카오 번호를 검증한 뒤에만 쓰인다.
  -- 새 번호 인증 성공 시 이전 안내 대상을 교체한다. 실패한 OTP는 여기 도달하지 않는다.
  new.login_hint_account_ids:='{}'::uuid[];
  if not exists(select 1 from public.member_phone_identities where user_id=new.user_id)
    and cardinality(public._member_phone_merge_candidates(new.user_id,new.phone))<2 then
    new.login_hint_account_ids:=public._member_existing_phone_account_ids(new.phone,new.user_id);
  end if;
  return new;
end;
$$;
create trigger remember_member_phone_login_hint
  before insert or update of phone,verified_at on public.member_phone_proofs
  for each row execute function public.remember_member_phone_login_hint();

revoke all on function public._member_existing_phone_account_ids(text,uuid),
  public._member_phone_login_hints(text,uuid,uuid[]),public.remember_member_phone_login_hint()
  from public,anon,authenticated;

create or replace function public.get_my_member_identity() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_phone text; v_proof public.member_phone_proofs%rowtype; v_target uuid; v_legacy boolean;
  v_status text; v_can_merge boolean:=false; v_remembered boolean:=false;
  v_accounts jsonb:='[]'::jsonb; v_account_ids uuid[];
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  select target_user_id into v_target from public.member_account_merges where source_user_id=auth.uid();
  select phone into v_phone from public.member_phone_identities where user_id=auth.uid();
  select * into v_proof from public.member_phone_proofs where user_id=auth.uid();
  v_legacy:=public._member_is_legacy_account(auth.uid());
  v_status:=case when v_target is not null then 'merged' when v_phone is not null then 'verified' else 'unverified' end;
  if v_status='unverified' and v_proof.phone is not null and public._member_phone_conflicts(auth.uid(),v_proof.phone) then
    if v_proof.expires_at>now() then
      v_can_merge:=cardinality(public._member_phone_merge_candidates(auth.uid(),v_proof.phone))>=2;
      if not v_can_merge then
        v_status:='existing_account';
        v_accounts:=public._member_existing_phone_accounts(v_proof.phone,auth.uid());
      end if;
    else
      v_account_ids:=v_proof.login_hint_account_ids;
      -- 배포 전에 이미 인증한 회원도 재인증 없이 복구한다. 소유 증명 당시 존재한
      -- 확인된 소유자/전환 전 번호 기록만 사용하고 이후 새 소유자는 노출하지 않는다.
      if v_account_ids is null and cardinality(public._member_phone_merge_candidates(auth.uid(),v_proof.phone))<2 then
        select coalesce(array_agg(u.id),'{}'::uuid[]) into v_account_ids from auth.users u
        where u.id=any(public._member_existing_phone_account_ids(v_proof.phone,auth.uid()))
          and u.created_at<=v_proof.verified_at
          and (exists(select 1 from public.member_phone_identities i where i.user_id=u.id
              and i.phone=v_proof.phone and i.verified_at<=v_proof.verified_at)
            or exists(select 1 from public.member_legacy_phone_accounts l where l.user_id=u.id and l.phone=v_proof.phone));
      end if;
      v_accounts:=public._member_phone_login_hints(v_proof.phone,auth.uid(),v_account_ids);
      if jsonb_array_length(v_accounts)>0 then v_status:='existing_account'; v_remembered:=true; end if;
    end if;
  end if;
  return public.get_member_identity_policy()||jsonb_build_object('status',v_status,'phone',v_phone,
    'is_legacy_account',v_legacy,'can_merge',v_can_merge,'existing_accounts',v_accounts,
    'existing_account_remembered',v_remembered);
end;
$$;

notify pgrst,'reload schema';
commit;
