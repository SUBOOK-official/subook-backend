-- 이벤트 알림 신청 파기 (2026-08-30)
--
-- event_subscriptions(휴대전화번호)를 개인정보 파기 크론에 편입:
--   1) 신청일 기준 6개월 경과 행 삭제 — 다이얼로그 약관 문구("동의 철회 시 또는
--      이벤트 종료 후 6개월")의 상한 내 보수적 파기. 별도 크론 없이 기존
--      subook-privacy-purge 잡(매일 KST 03:17)이 부르는 이 RPC에 편승한다.
--      ⚠ 조기 return(파기 대상 회원 0명) "앞"에 두어 매 실행마다 동작하게 함.
--   2) 탈퇴 회원의 신청 행은 즉시 삭제 (회원 파기 블록에 추가).
--
-- 그 외 본문은 프로덕션 pg_get_functiondef 덤프(2026-08-30) 그대로 —
-- 특히 orders 환불계좌 3컬럼 파기 블록은 유지 필수 (2026-08-13 도입).

begin;

CREATE OR REPLACE FUNCTION public.purge_expired_member_personal_data(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_ids uuid[];
  v_purged_count integer := 0;
  v_event_subs_purged integer := 0;
  v_optional_auth_sets text := '';
begin
  -- 이벤트 알림 신청 시간 기반 파기 — 회원 파기 대상이 없어도 매 실행마다 수행
  delete from public.event_subscriptions
  where created_at < now() - interval '6 months';
  get diagnostics v_event_subs_purged = row_count;

  select coalesce(array_agg(user_id), '{}'::uuid[]) into v_user_ids
  from (
    select user_id from public.member_profiles
    where withdrawal_requested_at is not null and withdrawal_scheduled_at <= now() and personal_data_erased_at is null
    order by withdrawal_scheduled_at asc
    limit greatest(1, least(coalesce(p_limit, 100), 1000))
  ) targets;

  if coalesce(array_length(v_user_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'purged_count', 0,
      'event_subscriptions_purged', v_event_subs_purged);
  end if;

  delete from public.member_shipping_addresses where user_id = any(v_user_ids);
  delete from public.member_settlement_accounts where user_id = any(v_user_ids);
  delete from public.cart_items where user_id = any(v_user_ids);
  -- 탈퇴 회원의 이벤트 알림 신청(전화번호)도 즉시 파기
  delete from public.event_subscriptions where user_id = any(v_user_ids);

  update public.pickup_requests set
    pickup_recipient_name = '탈퇴회원', pickup_recipient_phone = '00000000000',
    pickup_postal_code = '00000', pickup_address_line1 = '개인정보 파기', pickup_address_line2 = null, pickup_memo = null,
    settlement_bank_name = '파기', settlement_account_number = null, settlement_account_number_ciphertext = null,
    settlement_account_last4 = null, settlement_account_holder = '파기', updated_at = now()
  where user_id = any(v_user_ids);

  update public.orders set
    shipping_recipient_name = '탈퇴회원', shipping_recipient_phone = '00000000000',
    shipping_postal_code = '00000', shipping_address_line1 = '개인정보 파기', shipping_address_line2 = null, shipping_memo = null,
    refund_bank_name = null, refund_account_number = null, refund_account_holder = null,
    updated_at = now()
  where user_id = any(v_user_ids);

  update public.settlements set
    bank_name = null, account_number = null, account_number_ciphertext = null, account_number_last4 = null, account_holder = null, updated_at = now()
  where seller_user_id = any(v_user_ids);

  if to_regclass('public.notification_logs') is not null then
    update public.notification_logs set recipient_phone = '00000000000', recipient_name = null where recipient_user_id = any(v_user_ids);
  end if;

  update public.shipments set seller_name = '탈퇴회원', seller_phone = '00000000000' where user_id = any(v_user_ids);

  update public.member_profiles mp set
    email = 'withdrawn+' || replace(mp.user_id::text, '-', '') || '@deleted.subook.local',
    name = '탈퇴회원', nickname = '탈퇴회원', phone = null, marketing_opt_in = false,
    email_verified_at = null, terms_agreed_at = null, privacy_agreed_at = null, marketing_agreed_at = null,
    personal_data_erased_at = now(), updated_at = now()
  where mp.user_id = any(v_user_ids);

  if exists (select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='phone') then
    v_optional_auth_sets := v_optional_auth_sets || ', phone = null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='encrypted_password') then
    v_optional_auth_sets := v_optional_auth_sets || ', encrypted_password = null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='deleted_at') then
    v_optional_auth_sets := v_optional_auth_sets || ', deleted_at = coalesce(deleted_at, now())';
  end if;

  execute '
    update auth.users au set
      email = ''withdrawn+'' || replace(au.id::text, ''-'', '''') || ''@deleted.subook.local'',
      raw_user_meta_data = ''{}''::jsonb, updated_at = now() ' || v_optional_auth_sets || '
    where au.id = any($1)' using v_user_ids;

  get diagnostics v_purged_count = row_count;
  return jsonb_build_object('success', true, 'purged_count', v_purged_count,
    'event_subscriptions_purged', v_event_subs_purged);
end;
$function$;

commit;
