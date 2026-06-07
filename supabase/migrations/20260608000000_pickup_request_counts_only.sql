-- 수거신청 모델 변경: 사용자가 교재를 개별 등록하던 단계를 없애고,
-- "예상 권수 + 박스 개수"만 받는다. 실제 교재는 검수 단계에서 운영팀이 등록.
--
-- submit_pickup_request 변경점(시그니처 동일 — CREATE OR REPLACE):
--   1) 'At least one item is required' 제거 → p_items 0개 허용
--   2) 예상 권수(p_expected_book_count) / 박스 개수(p_box_count)를 필수화 + 양수 검증
--   3) pickup_requests.item_count = 예상 권수 (admin 목록/표시가 의미있는 수를 갖도록)
--   4) p_items가 비어 있으면 pickup_items에 아무것도 안 들어감(루프 0회) — 기존 호환 유지
-- 비파괴: CREATE OR REPLACE FUNCTION + grant. 스키마/데이터 변경 없음.

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

notify pgrst, 'reload schema';
