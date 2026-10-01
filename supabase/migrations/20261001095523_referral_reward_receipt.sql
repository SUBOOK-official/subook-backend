-- 본인 초대의 지급 완료 내역만 반환한다. 원장/타인 프로필의 직접 접근 권한은 유지한다.
-- Rollback: 20261001060942의 get_my_signup_referral() 정의만 복원한다.
begin;

create or replace function public.get_my_signup_referral()
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_user uuid := auth.uid();
  v_code text;
  v_reward jsonb;
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

  -- 통합으로 승계한 초대도 이미 사용한 1회 혜택이다. 이름은 서버에서 마스킹한다.
  select jsonb_build_object(
    'friend_name', case when friend_name is null then null
      when char_length(friend_name) = 1 then '*'
      when char_length(friend_name) = 2 then left(friend_name, 1) || '*'
      else left(friend_name, 1) || repeat('*', char_length(friend_name) - 2) || right(friend_name, 1) end,
    'rewarded_at', rewarded_at
  ) into v_reward
  from (
    select s.rewarded_at, case when m.withdrawal_requested_at is null and m.personal_data_erased_at is null
      then left(nullif(btrim(m.name), ''), 24) else null end as friend_name
    from public.member_referral_signups s
    left join public.member_profiles m on m.user_id = s.invitee_id
    where s.rewarded_at is not null and (s.inviter_id = v_user or s.inviter_id in (
      select source_user_id from public.member_account_merges where target_user_id = v_user
    ))
    order by s.rewarded_at, s.invitee_id
    limit 1
  ) reward;

  return jsonb_build_object('code', v_code,
    'can_invite', not public._referral_inviter_used(v_user),
    'reward_count', (select count(*) from public.member_referral_signups where inviter_id = v_user and rewarded_at is not null),
    'received_reward', exists (select 1 from public.member_referral_signups where invitee_id = v_user and rewarded_at is not null),
    'sent_reward', v_reward);
end;
$function$;
revoke all on function public.get_my_signup_referral() from public, anon;
grant execute on function public.get_my_signup_referral() to authenticated;

select pg_notify('pgrst', 'reload schema');
commit;
