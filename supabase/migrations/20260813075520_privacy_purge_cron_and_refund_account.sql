-- 탈퇴회원 개인정보 파기 크론 복구 + orders 환불계좌 파기 누락 보완 (2026-08-13)
--
-- 배경 1 (크론 미등록): 2026041206·20260602040000의 subook-privacy-purge 등록 블록은
--   `if to_regnamespace('cron') is not null` 조건부였는데, 당시 prod에 pg_cron 확장이
--   미설치라 조용히 no-op됨. 7/31의 pg_cron 설치 마이그레이션(20260731175117)은
--   subook-expire-unpaid-orders만 복구해서, 파기 잡은 여전히 미등록 상태였다.
--   첫 파기 기한이 2026-08-27(탈퇴 대기 2건)이라 그 전에 등록 필요.
--
-- 배경 2 (환불계좌 파기 누락): 20260712083102에서 orders에 환불계좌 3컬럼
--   (refund_bank_name / refund_account_number / refund_account_holder, 평문)이
--   추가됐지만, 파기 RPC(20260602040000)는 orders의 shipping_* 필드만 마스킹하고
--   환불계좌는 남겨두고 있었다.
--
-- 변경 (비파괴):
--   1) purge_expired_member_personal_data 재정의 — 기존 파기 로직(주소/정산계좌/장바구니
--      삭제, pickup·orders·settlements·notification_logs·shipments 마스킹,
--      member_profiles·auth.users 익명화) 전부 유지 + orders 환불계좌 3컬럼 null 처리 추가.
--   2) subook-privacy-purge 데일리 잡 (재)등록 — 20260602040000과 동일한 잡 이름·주기
--      ('17 18 * * *' UTC = KST 03:17). unschedule 후 schedule이라 재실행에도 멱등.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 파기 RPC 재정의 (20260602040000 정의 + orders 환불계좌 3컬럼 파기 추가)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.purge_expired_member_personal_data(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_ids uuid[];
  v_purged_count integer := 0;
  v_optional_auth_sets text := '';
begin
  select coalesce(array_agg(user_id), '{}'::uuid[]) into v_user_ids
  from (
    select user_id from public.member_profiles
    where withdrawal_requested_at is not null and withdrawal_scheduled_at <= now() and personal_data_erased_at is null
    order by withdrawal_scheduled_at asc
    limit greatest(1, least(coalesce(p_limit, 100), 1000))
  ) targets;

  if coalesce(array_length(v_user_ids, 1), 0) = 0 then
    return jsonb_build_object('success', true, 'purged_count', 0);
  end if;

  delete from public.member_shipping_addresses where user_id = any(v_user_ids);
  delete from public.member_settlement_accounts where user_id = any(v_user_ids);
  delete from public.cart_items where user_id = any(v_user_ids);

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
  return jsonb_build_object('success', true, 'purged_count', v_purged_count);
end;
$$;

revoke execute on function public.purge_expired_member_personal_data(integer) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) subook-privacy-purge 데일리 잡 등록 (pg_cron은 20260731175117에서 설치 완료)
-- ─────────────────────────────────────────────────────────────────────────────
do $$
begin
  begin
    perform cron.unschedule('subook-privacy-purge');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'subook-privacy-purge',
    '17 18 * * *',
    $job$ select public.run_privacy_retention_job(); $job$
  );
end $$;

commit;
