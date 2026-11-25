-- 전환 전 계정이 번호를 인증할 때, 이용 이력이 없는 다른 전환 전 계정의 "가입 때 적어둔 번호"는
-- 걸림돌로 치지 않는다. 그 번호 기록은 인증된 적 없는 입력값이고, 빈 계정에는 옮길 내역이 없다.
--
-- 배경(2026-11-26 제보): 주문 이력이 있는 본 계정이 번호를 인증했는데, 같은 번호가 적힌 빈 계정 2개로
-- 로그인하라는 안내가 나왔다. 안내대로 하면 빈 계정이 번호 주인이 되어 본 계정이 그 번호를 쓸 수 없게 된다.
--
-- 바뀌는 것
--   1) _member_phone_conflicts        : 인증하는 계정이 전환 전 회원이면 빈 계정의 번호 기록은 충돌 아님
--   2) _member_phone_merge_candidates : 통합 후보에서 빈 계정 제외(본인·인증된 번호 주인은 그대로 포함)
--   3) _member_existing_phone_account_ids : 이력 있는 계정이 있으면 그 계정만 안내
-- 그대로인 것
--   - 신규 가입·전환 뒤 만든 계정이 기존 번호와 겹치면 지금처럼 기존 계정 로그인 안내(쿠폰 중복 방지)
--   - 관리자 겸용 계정의 번호 기록은 이력과 무관하게 계속 충돌로 본다(관리자 보호 유지)
--   - 인증된 번호 주인(member_phone_identities), 1번호 1계정, 대표 계정 선택 통합의 로그인 증명
--   - 회원·번호 기록·통합 이력 데이터는 수정하지 않는다. 빈 계정도 삭제하지 않는다.
--
-- 롤백: 아래 세 함수를 20261001091226(_member_phone_conflicts), 20261001104338(_member_phone_merge_candidates),
--       20261004161015(_member_existing_phone_account_ids) 정의로 복원하고 새 함수 2개를 drop. 데이터 변경 없음.
begin;

-- 전환 전에 만든 계정이면서 회원 프로필이 있는 경우만 완화 대상이다.
-- 프로필 없는 과거 OAuth 기록은 신규 가입과 같으므로 기존의 엄격한 규칙을 따른다.
create function public._member_is_legacy_member(p_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select public._member_is_legacy_account(p_user_id)
    and exists(select 1 from public.member_profiles m where m.user_id=p_user_id);
$$;

-- 번호 기록이 다른 계정의 인증을 막을 만큼 "무게"가 있는가: 이용 이력이 있거나 관리자 겸용.
-- 장바구니·찜·배송지·정산계좌·미사용 쿠폰·구사이트 고객 연결만 있는 계정은 빈 계정으로 본다.
create function public._member_phone_record_holds(p_user_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.orders where user_id=p_user_id)
    or exists(select 1 from public.pg_checkout_sessions where user_id=p_user_id)
    or exists(select 1 from public.pickup_requests where user_id=p_user_id)
    or exists(select 1 from public.shipments where user_id=p_user_id)
    or exists(select 1 from public.settlements where seller_user_id=p_user_id)
    or exists(select 1 from public.point_lots where user_id=p_user_id)
    or exists(select 1 from public.point_transactions where user_id=p_user_id)
    or exists(select 1 from public.reviews where user_id=p_user_id)
    or exists(select 1 from public.legacy_reviews where user_id=p_user_id)
    or exists(select 1 from public.member_coupons where user_id=p_user_id and used_at is not null)
    or exists(select 1 from public.member_profiles m join public.admin_users a on lower(a.email)=lower(m.email)
      where m.user_id=p_user_id);
$$;
revoke all on function public._member_is_legacy_member(uuid),public._member_phone_record_holds(uuid)
  from public,anon,authenticated;

create or replace function public._member_phone_conflicts(p_user_id uuid,p_phone text) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.member_phone_identities where phone=p_phone and user_id is distinct from p_user_id)
    or exists(select 1 from public.member_profiles m join public.member_legacy_phone_accounts l on l.user_id=m.user_id
      where m.user_id is distinct from p_user_id and l.phone=p_phone and m.personal_data_erased_at is null
        and not exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone<>p_phone)
        and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id)
        -- 가입 전(p_user_id null)·전환 뒤 계정에는 모든 번호 기록이 충돌이다.
        and (not public._member_is_legacy_member(p_user_id) or public._member_phone_record_holds(m.user_id)));
$$;

create or replace function public._member_phone_merge_candidates(p_user_id uuid,p_phone text) returns uuid[]
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
      -- 빈 계정은 합칠 내역이 없으므로 후보로 세우지 않는다.
      or (exists(select 1 from public.member_legacy_phone_accounts l where l.user_id=m.user_id and l.phone=p_phone)
        and public._member_phone_record_holds(m.user_id))
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

create or replace function public._member_existing_phone_account_ids(p_phone text,p_exclude_user_id uuid) returns uuid[]
language sql stable security definer set search_path='' as $$
  with owner as (
    select user_id from public.member_phone_identities where phone=p_phone
  ), linked as (
    -- 인증된 번호 주인이 있으면 그 계정만, 없으면 전환 전 번호 기록을 가진 계정.
    select user_id,true as is_owner from owner
    union all
    select l.user_id,false from public.member_legacy_phone_accounts l
    where l.phone=p_phone and not exists(select 1 from owner)
      and not exists(select 1 from public.member_phone_identities i where i.user_id=l.user_id and i.phone<>p_phone)
  ), active as (
    select u.id,u.created_at,(k.is_owner or public._member_phone_record_holds(u.id)) as holds
    from linked k join auth.users u on u.id=k.user_id join public.member_profiles m on m.user_id=u.id
    where u.id is distinct from p_exclude_user_id and u.deleted_at is null
      and m.personal_data_erased_at is null and m.withdrawal_requested_at is null and not coalesce(m.is_blocked,false)
      and not exists(select 1 from public.member_account_merges x where x.source_user_id=u.id)
  ), picked as (
    -- 이력 있는 계정이 하나라도 있으면 그 계정만 안내한다.
    -- 전부 빈 계정이면 신규 가입·전환 뒤 계정에게만 안내한다(전환 전 회원에게는 충돌이 아니다).
    select id,created_at from active
    where holds or (not exists(select 1 from active where holds) and not public._member_is_legacy_member(p_exclude_user_id))
    order by created_at,id limit 5
  )
  select coalesce(array_agg(id order by created_at,id),'{}'::uuid[]) from picked;
$$;

commit;
