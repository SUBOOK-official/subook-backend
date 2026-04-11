-- 수거 요청 (판매자가 교재를 보내는 플로우)
create table if not exists public.pickup_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_number text not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'pickup_scheduled', 'picking_up', 'arrived', 'inspecting', 'inspected', 'completed', 'cancelled')),

  -- 수거 주소
  pickup_recipient_name text not null,
  pickup_recipient_phone text not null,
  pickup_postal_code text not null,
  pickup_address_line1 text not null,
  pickup_address_line2 text null,
  pickup_memo text null,

  -- 정산 계좌
  settlement_bank_name text not null,
  settlement_account_number text not null,
  settlement_account_holder text not null,

  -- 정책 동의
  policy_agreed_at timestamptz not null,

  -- CJ 물류 연동
  tracking_number text null,
  tracking_carrier text null default 'CJ대한통운',

  item_count integer not null default 0 check (item_count >= 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 수거 요청 교재 (각 교재 항목)
create table if not exists public.pickup_items (
  id bigint generated always as identity primary key,
  pickup_request_id bigint not null references public.pickup_requests(id) on delete cascade,

  -- 교재 DB에서 선택한 경우
  book_id bigint null,

  -- 교재 정보 (DB 매칭 / 직접 입력 공통)
  title text not null,
  subject text null check (subject is null or subject in ('국어', '수학', '영어', '과학', '사회', '한국사', '기타')),
  brand text null,
  book_type text null check (book_type is null or book_type in ('기출', '모의고사', 'N제', 'EBS', '주간지', '내신', '기타')),
  published_year integer null check (published_year is null or (published_year >= 2000 and published_year <= 2100)),
  instructor_name text null,
  original_price integer null check (original_price is null or original_price >= 0),

  -- 판매자 입력
  condition_memo text null,
  cover_photo_url text null,
  is_manual_entry boolean not null default false,

  created_at timestamptz not null default now()
);

-- 인덱스
create index if not exists idx_pickup_requests_user_id
  on public.pickup_requests (user_id, created_at desc);

create index if not exists idx_pickup_requests_status
  on public.pickup_requests (status);

create index if not exists idx_pickup_items_request_id
  on public.pickup_items (pickup_request_id);

-- RLS 활성화
alter table public.pickup_requests enable row level security;
alter table public.pickup_items enable row level security;

-- RLS 정책: 사용자는 자기 데이터만 접근
create policy "pickup_requests_select_own"
  on public.pickup_requests for select
  to authenticated
  using (user_id = auth.uid());

create policy "pickup_requests_insert_own"
  on public.pickup_requests for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "pickup_requests_update_own"
  on public.pickup_requests for update
  to authenticated
  using (user_id = auth.uid());

create policy "pickup_items_select_own"
  on public.pickup_items for select
  to authenticated
  using (
    pickup_request_id in (
      select id from public.pickup_requests where user_id = auth.uid()
    )
  );

create policy "pickup_items_insert_own"
  on public.pickup_items for insert
  to authenticated
  with check (
    pickup_request_id in (
      select id from public.pickup_requests where user_id = auth.uid()
    )
  );

-- 관리자 전체 접근
create policy "pickup_requests_admin_all"
  on public.pickup_requests for all
  to authenticated
  using (public.is_admin_user());

create policy "pickup_items_admin_all"
  on public.pickup_items for all
  to authenticated
  using (public.is_admin_user());

-- 요청번호 생성 함수
create or replace function public.generate_pickup_request_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  next_number text;
  year_month text;
  seq_number integer;
begin
  year_month := to_char(now(), 'YYMM');

  select coalesce(max(
    nullif(regexp_replace(request_number, '^PU-' || year_month || '-', ''), request_number)::integer
  ), 0) + 1
  into seq_number
  from public.pickup_requests
  where request_number like 'PU-' || year_month || '-%';

  next_number := 'PU-' || year_month || '-' || lpad(seq_number::text, 4, '0');
  return next_number;
end;
$$;

-- 수거 요청 제출 RPC
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
  p_items jsonb
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
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  v_item_count := jsonb_array_length(coalesce(p_items, '[]'::jsonb));
  if v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;

  v_request_number := public.generate_pickup_request_number();

  insert into public.pickup_requests (
    user_id, request_number, status,
    pickup_recipient_name, pickup_recipient_phone,
    pickup_postal_code, pickup_address_line1, pickup_address_line2, pickup_memo,
    settlement_bank_name, settlement_account_number, settlement_account_holder,
    policy_agreed_at, item_count
  ) values (
    v_user_id, v_request_number, 'pending',
    p_pickup_recipient_name, p_pickup_recipient_phone,
    p_pickup_postal_code, p_pickup_address_line1, p_pickup_address_line2, p_pickup_memo,
    p_settlement_bank_name, p_settlement_account_number, p_settlement_account_holder,
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
    'item_count', v_item_count
  );
end;
$$;

-- 교재 DB 검색 RPC (수거 요청 시 교재 검색용)
create or replace function public.search_books_for_pickup(
  p_search text,
  p_limit integer default 10
)
returns table (
  id bigint,
  title text,
  option text,
  subject text,
  brand text,
  book_type text,
  published_year integer,
  instructor_name text,
  original_price integer
)
language sql
stable
security definer
set search_path = public
as $$
  select distinct on (p.id)
    p.id,
    p.title,
    p.option,
    p.subject,
    p.brand,
    p.book_type,
    p.published_year,
    p.instructor_name,
    (select b.original_price from public.books b where b.product_id = p.id and b.original_price is not null limit 1) as original_price
  from public.products p
  where p.status <> 'hidden'
    and (
      p.title ilike '%' || btrim(p_search) || '%'
      or p.brand ilike '%' || btrim(p_search) || '%'
      or coalesce(p.instructor_name, '') ilike '%' || btrim(p_search) || '%'
    )
  order by p.id desc
  limit least(p_limit, 20);
$$;
