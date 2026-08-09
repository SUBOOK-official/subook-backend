-- 장난/시험 수거신청 방어 (2026-08-10, 사용자 결정 a+b안)
--
-- (a) submit_pickup_request: 연락처는 본인이 휴대폰 인증(OTP)을 통과한 번호만 허용.
--     - 기존 OTP 인프라 재사용: 발송=public-web /api/auth/send-phone-otp(레이트리밋),
--       검증=verify_phone_otp RPC → member_profiles.verified_phone/phone_verified_at 기록.
--     - 이미 인증한 번호(verified_phone 일치)면 추가 절차 없이 통과 — 폼에서도 인증 UI 생략.
--     ⚠ 배포 순서: public-web(인증 UI) 프로덕션 반영 후에 이 마이그레이션을 적용할 것.
--       (강제를 먼저 켜면 구 번들 사용자는 인증 수단 없이 제출이 막힘)
--
-- (b) list_admin_pickup_requests: 접수 전 신뢰 신호 4종 반환 —
--     member_since(가입일) / phone_verified(이 신청 연락처가 인증된 번호인지) /
--     prior_pickup_count(실제 진행된 과거 수거 수) / duplicate_pending_count(동일
--     회원·번호의 다른 대기 신청 수). 반환 테이블이 바뀌므로 drop 후 재생성.
--
-- ⚠ submit_pickup_request 재정의 시 유지 필수: 휴대폰 인증 강제 블록,
--   계좌 자동 등록 블록(20260809170300), assert_member_not_blocked,
--   예상권수/박스 필수 검증, p_items 0개 허용.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) submit_pickup_request — 인증된 연락처 강제
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.submit_pickup_request(
  p_pickup_recipient_name text,
  p_pickup_recipient_phone text,
  p_pickup_postal_code text,
  p_pickup_address_line1 text,
  p_pickup_address_line2 text,
  p_pickup_memo text,
  p_settlement_bank_name text,
  p_settlement_account_number text,
  p_settlement_account_holder text,
  p_items jsonb,
  p_settlement_account_id bigint default null,
  p_pickup_email text default null,
  p_pickup_entrance_password text default null,
  p_desired_pickup_date date default null,
  p_expected_book_count integer default null,
  p_box_count integer default null,
  p_policy_agreed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_request_id bigint;
  v_request_number text;
  v_item jsonb;
  v_item_count integer;
  v_account record;
  v_bank_name text;
  v_account_holder text;
  v_account_digits text;
  v_account_ciphertext bytea;
  v_account_last4 text;
  v_saved_account_id bigint;
  v_pickup_email text;
  v_entrance_password text;
  v_expected_book_count integer;
  v_box_count integer;
  v_phone_digits text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  if not coalesce(p_policy_agreed, false) then
    raise exception '수거 신청은 이용약관 및 개인정보처리방침 동의가 필요합니다.';
  end if;

  -- 장난/시험 신청 방어(2026-08-10): 연락처는 본인이 휴대폰 인증(OTP)을 통과한 번호만
  -- 허용한다. 가입/이전 인증으로 verified_phone이 이미 일치하면 추가 절차 없이 통과.
  v_phone_digits := regexp_replace(coalesce(p_pickup_recipient_phone, ''), '[^0-9]', '', 'g');
  if length(v_phone_digits) < 10
     or not exists (
       select 1
       from public.member_profiles mp
       where mp.user_id = v_user_id
         and mp.phone_verified_at is not null
         and mp.verified_phone = v_phone_digits
     ) then
    raise exception '수거 신청에는 연락처 휴대폰 인증이 필요합니다. 연락처 번호를 인증한 뒤 다시 시도해 주세요.';
  end if;

  -- 신규 모델: 사용자는 교재를 개별 등록하지 않는다(검수 때 운영팀이 등록).
  -- p_items는 비어 있는 게 정상이며, 0개여도 막지 않는다.
  v_item_count := jsonb_array_length(coalesce(p_items, '[]'::jsonb));

  if p_settlement_account_id is not null then
    select
      msa.bank_name,
      msa.account_holder,
      msa.account_number_ciphertext,
      coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number)) as account_last4,
      public.decrypt_account_number(msa.account_number_ciphertext) as decrypted_account_number,
      msa.account_number as legacy_account_number
    into v_account
    from public.member_settlement_accounts msa
    where msa.user_id = v_user_id
      and msa.id = p_settlement_account_id;

    if not found then
      raise exception 'Settlement account not found';
    end if;

    v_bank_name := v_account.bank_name;
    v_account_holder := v_account.account_holder;
    v_account_digits := coalesce(
      public.normalize_account_number(v_account.decrypted_account_number),
      public.normalize_account_number(v_account.legacy_account_number)
    );
    v_account_ciphertext := coalesce(
      v_account.account_number_ciphertext,
      public.encrypt_account_number(v_account_digits)
    );
    v_account_last4 := coalesce(v_account.account_last4, public.get_account_last4(v_account_digits));
  else
    v_bank_name := nullif(btrim(coalesce(p_settlement_bank_name, '')), '');
    v_account_holder := nullif(btrim(coalesce(p_settlement_account_holder, '')), '');
    v_account_digits := public.normalize_account_number(p_settlement_account_number);
    v_account_ciphertext := public.encrypt_account_number(v_account_digits);
    v_account_last4 := public.get_account_last4(v_account_digits);
  end if;

  if v_bank_name is null or v_account_holder is null or v_account_ciphertext is null then
    raise exception 'Settlement account information is required';
  end if;

  -- 폼에 직접 입력한 계좌는 기본 정산계좌로 자동 등록 (2026-08-09).
  -- 같은 번호의 계좌가 이미 있으면 새로 만들지 않고 그 계좌를 기본으로 승격하고
  -- 은행/예금주만 최신 입력으로 갱신한다.
  if p_settlement_account_id is null and v_account_digits is not null then
    select msa.id
      into v_saved_account_id
      from public.member_settlement_accounts msa
      where msa.user_id = v_user_id
        and coalesce(
          public.normalize_account_number(public.decrypt_account_number(msa.account_number_ciphertext)),
          public.normalize_account_number(msa.account_number)
        ) = v_account_digits
      order by msa.is_default desc, msa.id
      limit 1;

    if v_saved_account_id is null then
      insert into public.member_settlement_accounts (
        user_id, bank_name, account_number, account_number_ciphertext, account_number_last4,
        account_holder, is_default
      ) values (
        v_user_id, v_bank_name,
        public.mask_account_number(v_account_last4),
        v_account_ciphertext, v_account_last4, v_account_holder, false
      ) returning id into v_saved_account_id;
    else
      update public.member_settlement_accounts
      set bank_name = v_bank_name,
          account_holder = v_account_holder
      where id = v_saved_account_id
        and (bank_name is distinct from v_bank_name or account_holder is distinct from v_account_holder);
    end if;

    update public.member_settlement_accounts
    set is_default = false
    where user_id = v_user_id
      and is_default
      and id <> v_saved_account_id;

    update public.member_settlement_accounts
    set is_default = true
    where id = v_saved_account_id
      and not is_default;
  end if;

  v_pickup_email := nullif(btrim(coalesce(p_pickup_email, '')), '');
  v_entrance_password := nullif(btrim(coalesce(p_pickup_entrance_password, '')), '');

  -- 예상 권수 / 박스 개수 필수화 (신규 모델의 핵심 입력값).
  v_expected_book_count := p_expected_book_count;
  v_box_count := p_box_count;
  if v_expected_book_count is null or v_expected_book_count <= 0 then
    raise exception '예상 권수를 입력해 주세요.';
  end if;
  if v_box_count is null or v_box_count <= 0 then
    raise exception '박스 개수를 입력해 주세요.';
  end if;

  v_request_number := public.generate_pickup_request_number();

  insert into public.pickup_requests (
    user_id, request_number, status,
    pickup_recipient_name, pickup_recipient_phone,
    pickup_postal_code, pickup_address_line1, pickup_address_line2, pickup_memo,
    pickup_email, pickup_entrance_password,
    desired_pickup_date, expected_book_count, box_count,
    settlement_bank_name, settlement_account_number, settlement_account_number_ciphertext,
    settlement_account_last4, settlement_account_holder,
    policy_agreed_at, item_count
  ) values (
    v_user_id, v_request_number, 'pending',
    p_pickup_recipient_name, p_pickup_recipient_phone,
    p_pickup_postal_code, p_pickup_address_line1, p_pickup_address_line2, p_pickup_memo,
    v_pickup_email, v_entrance_password,
    p_desired_pickup_date, v_expected_book_count, v_box_count,
    v_bank_name, public.mask_account_number(v_account_last4), v_account_ciphertext,
    v_account_last4, v_account_holder,
    now(), v_expected_book_count
  )
  returning id into v_request_id;

  -- p_items가 비어 있으면 루프 0회(신규 모델 정상). 값이 오면 호환 위해 그대로 저장.
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    insert into public.pickup_items (
      pickup_request_id,
      book_id,
      title, subject, brand, book_type,
      published_year, instructor_name, original_price,
      condition_memo, is_manual_entry
    ) values (
      v_request_id,
      case when (v_item->>'book_id') is not null and (v_item->>'book_id') <> ''
        then (v_item->>'book_id')::bigint else null end,
      v_item->>'title',
      nullif(btrim(v_item->>'subject'), ''),
      nullif(btrim(v_item->>'brand'), ''),
      nullif(btrim(v_item->>'book_type'), ''),
      case when (v_item->>'published_year') is not null and (v_item->>'published_year') <> ''
        then (v_item->>'published_year')::integer else null end,
      nullif(btrim(v_item->>'instructor_name'), ''),
      case when (v_item->>'original_price') is not null and (v_item->>'original_price') <> ''
        then (v_item->>'original_price')::integer else null end,
      nullif(btrim(v_item->>'condition_memo'), ''),
      coalesce((v_item->>'is_manual_entry')::boolean, false)
    );
  end loop;

  return jsonb_build_object(
    'request_id', v_request_id,
    'request_number', v_request_number,
    'item_count', v_expected_book_count,
    'expected_book_count', v_expected_book_count,
    'box_count', v_box_count,
    'settlement_account_last4', v_account_last4
  );
end;
$$;

grant execute on function public.submit_pickup_request(
  text, text, text, text, text, text, text, text, text, jsonb,
  bigint, text, text, date, integer, integer, boolean
) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) list_admin_pickup_requests — 접수 전 신뢰 신호 4종 추가
--    (20260808145829 최신 정의 기반 — 검색/필터/박스 송장 반환 그대로 유지)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.list_admin_pickup_requests(
  text, text[], date, date, integer, integer
);

create or replace function public.list_admin_pickup_requests(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (
  id bigint,
  user_id uuid,
  request_number text,
  status text,
  pickup_recipient_name text,
  pickup_recipient_phone text,
  pickup_postal_code text,
  pickup_address_line1 text,
  pickup_address_line2 text,
  pickup_memo text,
  pickup_email text,
  pickup_entrance_password text,
  desired_pickup_date date,
  expected_book_count integer,
  box_count integer,
  item_count integer,
  tracking_number text,
  tracking_carrier text,
  cj_request_id text,
  cj_pickup_registered_at timestamptz,
  cj_tracking_status text,
  cj_tracking_status_code text,
  cj_tracking_last_checked_at timestamptz,
  box_waybills jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  member_since timestamptz,
  phone_verified boolean,
  prior_pickup_count integer,
  duplicate_pending_count integer,
  items jsonb,
  latest_logistics_event jsonb,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits,
      coalesce(cardinality(p_statuses), 0) as status_count
  ),
  filtered_pickups as (
    select pr.*
    from public.pickup_requests pr
    cross join params
    where public.is_admin_user()
      and (
        params.search_term = ''
        or pr.request_number ilike '%' || params.search_term || '%'
        or pr.pickup_recipient_name ilike '%' || params.search_term || '%'
        or pr.pickup_recipient_phone ilike '%' || params.search_term || '%'
        or coalesce(pr.tracking_number, '') ilike '%' || params.search_term || '%'
        or (
          params.search_digits <> ''
          and regexp_replace(pr.pickup_recipient_phone, '[^0-9]', '', 'g') like '%' || params.search_digits || '%'
        )
      )
      and (
        params.status_count = 0
        or pr.status = any(p_statuses)
      )
      and (
        p_from_date is null
        or pr.created_at >= p_from_date
      )
      and (
        p_to_date is null
        or pr.created_at < p_to_date + interval '1 day'
      )
  )
  select
    fp.id,
    fp.user_id,
    fp.request_number,
    fp.status,
    fp.pickup_recipient_name,
    fp.pickup_recipient_phone,
    fp.pickup_postal_code,
    fp.pickup_address_line1,
    fp.pickup_address_line2,
    fp.pickup_memo,
    fp.pickup_email,
    fp.pickup_entrance_password,
    fp.desired_pickup_date,
    fp.expected_book_count,
    fp.box_count,
    fp.item_count,
    fp.tracking_number,
    fp.tracking_carrier,
    fp.cj_request_id,
    fp.cj_pickup_registered_at,
    fp.cj_tracking_status,
    fp.cj_tracking_status_code,
    fp.cj_tracking_last_checked_at,
    fp.box_waybills,
    fp.created_at,
    fp.updated_at,
    -- 접수 전 신뢰 신호 (장난/시험 신청 선별용, 2026-08-10)
    mp.created_at as member_since,
    coalesce(
      mp.phone_verified_at is not null
        and mp.verified_phone = regexp_replace(coalesce(fp.pickup_recipient_phone, ''), '[^0-9]', '', 'g'),
      false
    ) as phone_verified,
    coalesce((
      select count(*)::integer
      from public.pickup_requests prior
      where prior.user_id = fp.user_id
        and prior.id <> fp.id
        and prior.status in ('pickup_scheduled', 'picking_up', 'arrived', 'inspecting', 'inspected', 'completed')
    ), 0) as prior_pickup_count,
    coalesce((
      select count(*)::integer
      from public.pickup_requests dup
      where dup.id <> fp.id
        and dup.status = 'pending'
        and (
          dup.user_id = fp.user_id
          or regexp_replace(coalesce(dup.pickup_recipient_phone, ''), '[^0-9]', '', 'g')
             = regexp_replace(coalesce(fp.pickup_recipient_phone, ''), '[^0-9]', '', 'g')
        )
    ), 0) as duplicate_pending_count,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pi.id,
        'title', pi.title,
        'subject', pi.subject,
        'brand', pi.brand,
        'book_type', pi.book_type,
        'published_year', pi.published_year,
        'instructor_name', pi.instructor_name,
        'original_price', pi.original_price,
        'condition_memo', pi.condition_memo,
        'is_manual_entry', pi.is_manual_entry
      ) order by pi.id)
      from public.pickup_items pi
      where pi.pickup_request_id = fp.id
    ), '[]'::jsonb) as items,
    (
      select jsonb_build_object(
        'event_type', ple.event_type,
        'status', ple.status,
        'tracking_number', ple.tracking_number,
        'status_code', ple.status_code,
        'status_text', ple.status_text,
        'error_message', ple.error_message,
        'created_at', ple.created_at
      )
      from public.pickup_logistics_events ple
      where ple.pickup_request_id = fp.id
      order by ple.created_at desc, ple.id desc
      limit 1
    ) as latest_logistics_event,
    count(*) over()::integer as total_count
  from filtered_pickups fp
  left join public.member_profiles mp
    on mp.user_id = fp.user_id
  order by fp.created_at desc, fp.id desc
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 30), 200));
$$;

grant execute on function public.list_admin_pickup_requests(text, text[], date, date, integer, integer)
  to authenticated;

notify pgrst, 'reload schema';
