-- TIER 1-4: CJ대한통운 API 연동
-- 수거 접수/배송 추적 메타데이터와 운영자 수거 목록 RPC를 제공한다.

alter table public.pickup_requests
  add column if not exists cj_request_id text null,
  add column if not exists cj_pickup_registered_at timestamptz null,
  add column if not exists cj_tracking_status text null,
  add column if not exists cj_tracking_status_code text null,
  add column if not exists cj_tracking_last_checked_at timestamptz null,
  add column if not exists cj_tracking_history jsonb not null default '[]'::jsonb,
  add column if not exists cj_pickup_response jsonb null,
  add column if not exists cj_tracking_response jsonb null;

create index if not exists idx_pickup_requests_tracking_number
  on public.pickup_requests (tracking_number)
  where tracking_number is not null;

create index if not exists idx_pickup_requests_cj_registered_at
  on public.pickup_requests (cj_pickup_registered_at desc)
  where cj_pickup_registered_at is not null;

create table if not exists public.pickup_logistics_events (
  id bigint generated always as identity primary key,
  pickup_request_id bigint not null references public.pickup_requests(id) on delete cascade,
  event_type text not null
    check (event_type in ('pickup_register', 'tracking_lookup')),
  status text not null
    check (status in ('success', 'failed')),
  tracking_number text null,
  status_code text null,
  status_text text null,
  payload jsonb null,
  error_message text null,
  created_at timestamptz not null default now()
);

create index if not exists idx_pickup_logistics_events_request_created_at
  on public.pickup_logistics_events (pickup_request_id, created_at desc);

create index if not exists idx_pickup_logistics_events_status
  on public.pickup_logistics_events (status, created_at desc);

alter table public.pickup_logistics_events enable row level security;

drop policy if exists pickup_logistics_events_select_own on public.pickup_logistics_events;
drop policy if exists pickup_logistics_events_admin_all on public.pickup_logistics_events;

create policy pickup_logistics_events_select_own
  on public.pickup_logistics_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.pickup_requests pr
      where pr.id = pickup_logistics_events.pickup_request_id
        and pr.user_id = auth.uid()
    )
  );

create policy pickup_logistics_events_admin_all
  on public.pickup_logistics_events
  for all
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create or replace function public.touch_pickup_requests_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists pickup_requests_set_updated_at on public.pickup_requests;
create trigger pickup_requests_set_updated_at
before update on public.pickup_requests
for each row
execute function public.touch_pickup_requests_updated_at();

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

create or replace function public.get_my_pickup_requests(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', pr.id,
      'request_number', pr.request_number,
      'status', pr.status,
      'item_count', pr.item_count,
      'tracking_number', pr.tracking_number,
      'tracking_carrier', pr.tracking_carrier,
      'cj_tracking_status', pr.cj_tracking_status,
      'cj_tracking_status_code', pr.cj_tracking_status_code,
      'cj_tracking_last_checked_at', pr.cj_tracking_last_checked_at,
      'created_at', pr.created_at,
      'updated_at', pr.updated_at,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', pi.id,
          'title', pi.title,
          'subject', pi.subject,
          'brand', pi.brand,
          'book_type', pi.book_type,
          'original_price', pi.original_price,
          'condition_memo', pi.condition_memo,
          'is_manual_entry', pi.is_manual_entry,
          'cover_photo_url', pi.cover_photo_url
        ) order by pi.id)
        from public.pickup_items pi
        where pi.pickup_request_id = pr.id
      ), '[]'::jsonb)
    ) as row_data
    from public.pickup_requests pr
    where pr.user_id = v_user_id
    order by pr.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;
