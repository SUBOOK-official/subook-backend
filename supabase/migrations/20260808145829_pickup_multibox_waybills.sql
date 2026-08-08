-- 멀티박스 수거 접수: 박스별 CJ 운송장 기록
--
-- 사고 배경(2026-08-08): box_count=2 수거 요청(PU-2608-0005)에 채번이 1건만 이뤄져
-- 기사 방문 시 송장이 1장뿐 → 1박스만 수거됨. CJ 규격(V3.9.4)상 운송장은 박스(개별
-- 화물)당 1장 필요하며, MPCK(합포장)는 반대로 여러 건을 한 송장에 합치는 개념.
-- cj-pickup.js가 box_count만큼 채번+RegBook하도록 개편되면서 박스별 운송장을 기록한다.
--
-- box_waybills 형식: [{"box_seq":1,"tracking_number":"...","cust_use_no":"...","registered_at":"..."}]
--   - box_seq 1의 tracking_number는 기존 tracking_number 컬럼(대표 운송장)과 동일하게 유지
--   - box_seq 2+의 CJ CUST_USE_NO는 "<request_number>-B<seq>" (CJ 접수 PK 중복 방지)
--   - 도입 전 접수분(레거시)은 배열이 비어 있음 — 코드에서 tracking_number 존재 시
--     box_seq 1 접수분으로 간주한다
-- 비파괴: 컬럼 추가 + RPC 재정의(반환 테이블 확장 → drop 후 재생성, grant 재부여)

alter table public.pickup_requests
  add column if not exists box_waybills jsonb not null default '[]'::jsonb;

comment on column public.pickup_requests.box_waybills is
  '박스별 CJ 운송장 [{box_seq, tracking_number, cust_use_no, registered_at}] — 대표(tracking_number)=box_seq 1';

-- ── list_admin_pickup_requests: box_waybills 반환 추가 ─────────────────────────
-- 반환 테이블이 바뀌므로 drop 후 재생성 (기존 검색/필터/권한 가드 그대로 유지)
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
