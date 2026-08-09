-- 수거신청 폼 정산계좌 → 기본 정산계좌 자동 등록 + 기존 제출분 백필
--
-- 배경(2026-08-09): 수거신청 폼에서 직접 입력한 정산계좌가 pickup_requests에만
--   저장되고 member_settlement_accounts로는 넘어가지 않아, 폼에 계좌를 낸 셀러도
--   정산 생성 시 "계좌 미등록"으로 잡히는 구멍이 있었음 (6명 확인).
--
-- 1) submit_pickup_request: 직접 입력 경로(p_settlement_account_id null)에서
--    입력 계좌를 기본 정산계좌로 자동 등록. 같은 번호가 이미 있으면 중복 생성
--    없이 그 계좌를 기본으로 승격 + 은행/예금주 최신화.
--    (저장 계좌 선택 경로는 기존 그대로 — 이미 등록된 계좌라 손대지 않음)
-- 2) 백필: 폼 계좌(암호문 보유)가 있는데 정산계좌가 0건인 회원 → 최신 제출분으로
--    기본 정산계좌 생성(암호문·last4 재사용). 이미 계좌가 있는 회원은 건드리지
--    않음(지급처를 소급 변경하지 않기 위해 — 이후 제출분부터 1)이 처리).
--
-- ⚠ submit_pickup_request 재정의 시 유지 필수: 계좌 자동 등록 블록,
--   assert_member_not_blocked, 예상권수/박스 필수 검증, p_items 0개 허용.

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
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  if not coalesce(p_policy_agreed, false) then
    raise exception '수거 신청은 이용약관 및 개인정보처리방침 동의가 필요합니다.';
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

-- ── 백필: 폼 계좌는 있는데 정산계좌 0건인 회원 → 최신 제출분으로 기본계좌 생성 ──
-- (암호문·last4를 그대로 재사용하므로 복호화 없이 안전. 이미 계좌가 있는 회원은 제외.)
with latest_form_account as (
  select distinct on (pr.user_id)
    pr.user_id,
    pr.settlement_bank_name,
    pr.settlement_account_number_ciphertext,
    pr.settlement_account_last4,
    pr.settlement_account_holder
  from public.pickup_requests pr
  where pr.user_id is not null
    and pr.settlement_account_number_ciphertext is not null
    and nullif(btrim(coalesce(pr.settlement_bank_name, '')), '') is not null
    and nullif(btrim(coalesce(pr.settlement_account_holder, '')), '') is not null
  order by pr.user_id, pr.created_at desc, pr.id desc
)
insert into public.member_settlement_accounts (
  user_id, bank_name, account_number, account_number_ciphertext, account_number_last4,
  account_holder, is_default
)
select
  lfa.user_id,
  btrim(lfa.settlement_bank_name),
  public.mask_account_number(lfa.settlement_account_last4),
  lfa.settlement_account_number_ciphertext,
  lfa.settlement_account_last4,
  btrim(lfa.settlement_account_holder),
  true
from latest_form_account lfa
where not exists (
  select 1 from public.member_settlement_accounts msa where msa.user_id = lfa.user_id
);

notify pgrst, 'reload schema';
