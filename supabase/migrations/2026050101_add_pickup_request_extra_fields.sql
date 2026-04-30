-- 수거 요청에 사용자 추가 입력 필드 저장
--   - pickup_email             : 알림용 이메일 (선택)
--   - pickup_entrance_password : 공동현관 비밀번호 (선택) — 택배기사 방문 시 참고
--   - desired_pickup_date      : 희망 수거일 (선택)
--   - expected_book_count      : 사용자가 예상한 권수 (선택)
--   - box_count                : 박스 개수 (선택)
-- 모두 nullable 로 두어 과거 데이터/요청과의 호환성을 유지함.

alter table public.pickup_requests
  add column if not exists pickup_email text null,
  add column if not exists pickup_entrance_password text null,
  add column if not exists desired_pickup_date date null,
  add column if not exists expected_book_count integer null,
  add column if not exists box_count integer null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pickup_requests_expected_book_count_check'
  ) then
    alter table public.pickup_requests
      add constraint pickup_requests_expected_book_count_check
      check (expected_book_count is null or expected_book_count >= 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'pickup_requests_box_count_check'
  ) then
    alter table public.pickup_requests
      add constraint pickup_requests_box_count_check
      check (box_count is null or box_count >= 0);
  end if;
end$$;

comment on column public.pickup_requests.pickup_entrance_password is
  '공동현관 비밀번호. 택배기사 방문 안내용으로만 사용됨. 사용자 자율 입력 (선택).';
comment on column public.pickup_requests.desired_pickup_date is
  '판매자가 희망하는 수거일. 실제 픽업일은 CJ 일정 기준으로 별도 결정.';
comment on column public.pickup_requests.expected_book_count is
  '판매자가 직접 추정한 교재 권수 (실제 검수 결과와 다를 수 있음).';
comment on column public.pickup_requests.box_count is
  '판매자가 사용한 박스 개수.';

-- 기존 RPC 시그니처 제거 후 신규 파라미터 포함하여 재생성
drop function if exists public.submit_pickup_request(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb,
  bigint
);

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
  p_box_count integer default null
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

  v_item_count := jsonb_array_length(coalesce(p_items, '[]'::jsonb));
  if v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;

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

  v_expected_book_count := case
    when p_expected_book_count is null then null
    when p_expected_book_count < 0 then null
    else p_expected_book_count
  end;
  v_box_count := case
    when p_box_count is null then null
    when p_box_count < 0 then null
    else p_box_count
  end;

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
    now(), v_item_count
  )
  returning id into v_request_id;

  for v_item in select * from jsonb_array_elements(p_items)
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
    'item_count', v_item_count,
    'settlement_account_last4', v_account_last4
  );
end;
$$;

grant execute on function public.submit_pickup_request(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb,
  bigint,
  text,
  text,
  date,
  integer,
  integer
) to authenticated;

-- 관리자 픽업 조회 RPC 도 새 필드를 함께 반환하도록 확장
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
  created_at timestamptz,
  updated_at timestamptz,
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
    fp.created_at,
    fp.updated_at,
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
  order by fp.created_at desc, fp.id desc
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 30), 200));
$$;

grant execute on function public.list_admin_pickup_requests(text, text[], date, date, integer, integer)
  to authenticated;
