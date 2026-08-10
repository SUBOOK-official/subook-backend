-- 병합 반영 읽기 경로 + 끊긴 브리지 복구 (2026-08-10)
--
-- 20260810093000의 후속. 병합(merged_into_id)을 실제 화면에 반영하고,
-- 위저드 경로로 등록돼 수거신청과 끊긴 기존 검수 건들을 이어 붙인다.
--
-- 1) get_my_pickup_requests — 병합된 신청은 원본에 흡수(중복 행 제거), 원본 아래에
--    자식 신청의 검수 결과까지 함께 보이게. 박스 수도 합산.
-- 2) list_admin_pickup_requests — 병합 상태와 브리지된 검수 건을 반환(배지·링크용).
-- 3) 데이터 복구:
--    · #55 → PU-2608-0002 (김영태)   · #56 → PU-2608-0001 (권현중)
--    · #57 → PU-2608-0005 (조이선) + user_id 연결
--    · PU-2608-0006 → PU-2608-0005 에 병합 (빈 검수 건 #58 정리)
--    전부 전화번호 일치를 조건에 걸어 잘못 붙는 일이 없게 했다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 셀러 마이페이지 — 병합 반영
-- ─────────────────────────────────────────────────────────────────────────────
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

  select coalesce(jsonb_agg(row_data order by sort_ts desc), '[]'::jsonb)
  into v_result
  from (
    select row_data, sort_ts
    from (
      -- 신규 플로우: 수거신청 기반. 병합된 신청(merged_into_id 있음)은 원본에 흡수돼 빠진다.
      select
        jsonb_build_object(
          'id', pr.id,
          'source', 'pickup_request',
          'request_number', pr.request_number,
          'status', pr.status,
          'item_count', pr.item_count,
          -- 병합된 자식 신청의 박스까지 합산 (박스 누락 재접수 케이스)
          'box_count', coalesce(pr.box_count, 0) + coalesce((
            select sum(coalesce(c.box_count, 0))::integer
            from public.pickup_requests c
            where c.merged_into_id = pr.id
          ), 0),
          'merged_request_numbers', coalesce((
            select jsonb_agg(c.request_number order by c.created_at)
            from public.pickup_requests c
            where c.merged_into_id = pr.id
          ), '[]'::jsonb),
          'expected_book_count', pr.expected_book_count,
          'desired_pickup_date', pr.desired_pickup_date,
          'tracking_number', pr.tracking_number,
          'tracking_carrier', pr.tracking_carrier,
          'cj_tracking_status', pr.cj_tracking_status,
          'cj_tracking_status_code', pr.cj_tracking_status_code,
          'cj_tracking_last_checked_at', pr.cj_tracking_last_checked_at,
          'created_at', pr.created_at,
          'updated_at', pr.updated_at,
          'items', coalesce(
            -- 1순위: 브리지된 shipment의 실제 검수 books (병합된 자식 신청 것까지 포함)
            (
              select jsonb_agg(jsonb_build_object(
                'id', b.id,
                'title', b.title,
                'option', b.option,
                'grade', b.condition_grade,
                'price', b.price,
                'original_price', b.original_price,
                'status', b.status,
                'rejection_reason', case when b.status = 'discarded' then b.discard_reason end,
                'rejection_photo_urls', coalesce(to_jsonb(b.inspection_image_urls), '[]'::jsonb),
                'inspector_note', b.inspection_notes,
                'inspected_at', b.inspected_at
              ) order by (b.status = 'discarded') desc, b.id)
              from public.books b
              join public.shipments s on s.id = b.shipment_id
              where s.pickup_request_id in (
                select c.id
                from public.pickup_requests c
                where c.id = pr.id or c.merged_into_id = pr.id
              )
            ),
            -- 2순위: 레거시 pickup_items (교재 개별등록 폐지 전 신청 호환)
            (
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
            ),
            '[]'::jsonb
          )
        ) as row_data,
        pr.created_at as sort_ts
      from public.pickup_requests pr
      where pr.user_id = v_user_id
        and pr.merged_into_id is null

      union all

      -- 레거시: 수거신청 없이 등록된 본인 shipment (구 수북/식스샵 시절 수거)
      select
        jsonb_build_object(
          'id', 'legacy-' || s.id::text,
          'source', 'legacy_shipment',
          'legacy_shipment_id', s.id,
          'request_number', null,
          'status', case s.status
            when 'inspected' then 'inspected'
            when 'scheduled' then 'pickup_scheduled'
            else s.status
          end,
          'item_count', (
            select count(*) from public.books b where b.shipment_id = s.id
          ),
          'box_count', s.box_count,
          'merged_request_numbers', '[]'::jsonb,
          'expected_book_count', null,
          'desired_pickup_date', s.pickup_date,
          'tracking_number', null,
          'tracking_carrier', null,
          'cj_tracking_status', null,
          'cj_tracking_status_code', null,
          'cj_tracking_last_checked_at', null,
          'created_at', s.created_at,
          'updated_at', s.created_at,
          'items', coalesce(
            (
              select jsonb_agg(jsonb_build_object(
                'id', b.id,
                'title', b.title,
                'option', b.option,
                'grade', b.condition_grade,
                'price', b.price,
                'original_price', b.original_price,
                'status', b.status,
                'rejection_reason', case when b.status = 'discarded' then b.discard_reason end,
                'rejection_photo_urls', coalesce(to_jsonb(b.inspection_image_urls), '[]'::jsonb),
                'inspector_note', b.inspection_notes,
                'inspected_at', b.inspected_at
              ) order by (b.status = 'discarded') desc, b.id)
              from public.books b
              where b.shipment_id = s.id
            ),
            '[]'::jsonb
          )
        ) as row_data,
        s.created_at as sort_ts
      from public.shipments s
      where s.user_id = v_user_id
        and s.pickup_request_id is null
    ) merged
    order by sort_ts desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.get_my_pickup_requests(integer, integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 어드민 수거신청 목록 — 병합 상태 + 브리지된 검수 건 노출
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.list_admin_pickup_requests(text, text[], date, date, integer, integer);

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
  merged_into_id bigint,
  merged_into_request_number text,
  merged_child_count integer,
  merged_child_numbers jsonb,
  bridged_shipment_id bigint,
  bridged_book_count integer,
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
    -- 병합 상태 (2026-08-10)
    fp.merged_into_id,
    (select parent.request_number from public.pickup_requests parent where parent.id = fp.merged_into_id)
      as merged_into_request_number,
    coalesce((
      select count(*)::integer
      from public.pickup_requests child
      where child.merged_into_id = fp.id
    ), 0) as merged_child_count,
    coalesce((
      select jsonb_agg(child.request_number order by child.created_at)
      from public.pickup_requests child
      where child.merged_into_id = fp.id
    ), '[]'::jsonb) as merged_child_numbers,
    (
      select s.id from public.shipments s
      where s.pickup_request_id = fp.id
      order by s.id limit 1
    ) as bridged_shipment_id,
    coalesce((
      select count(*)::integer
      from public.books b
      join public.shipments s on s.id = b.shipment_id
      where s.pickup_request_id = fp.id
    ), 0) as bridged_book_count,
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

grant execute on function public.list_admin_pickup_requests(text, text[], date, date, integer, integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 데이터 복구 — 위저드 경로로 등록돼 끊긴 브리지 잇기
--    전화번호 일치를 조건에 넣어 대상이 다르면 아무 것도 안 바뀐다(무해한 no-op).
-- ─────────────────────────────────────────────────────────────────────────────
-- (a) 검수 건 ↔ 수거신청 브리지 복구
update public.shipments s
set pickup_request_id = pr.id,
    user_id = coalesce(s.user_id, pr.user_id)
from public.pickup_requests pr
where pr.request_number = 'PU-2608-0002'   -- 김영태
  and s.id = 55
  and s.pickup_request_id is null
  and regexp_replace(coalesce(s.seller_phone, ''), '[^0-9]', '', 'g')
      = regexp_replace(coalesce(pr.pickup_recipient_phone, ''), '[^0-9]', '', 'g');

update public.shipments s
set pickup_request_id = pr.id,
    user_id = coalesce(s.user_id, pr.user_id)
from public.pickup_requests pr
where pr.request_number = 'PU-2608-0001'   -- 권현중
  and s.id = 56
  and s.pickup_request_id is null
  and regexp_replace(coalesce(s.seller_phone, ''), '[^0-9]', '', 'g')
      = regexp_replace(coalesce(pr.pickup_recipient_phone, ''), '[^0-9]', '', 'g');

update public.shipments s
set pickup_request_id = pr.id,
    user_id = coalesce(s.user_id, pr.user_id)
from public.pickup_requests pr
where pr.request_number = 'PU-2608-0005'   -- 조이선 (박스1 검수분, user_id도 함께 복구)
  and s.id = 57
  and s.pickup_request_id is null
  and regexp_replace(coalesce(s.seller_phone, ''), '[^0-9]', '', 'g')
      = regexp_replace(coalesce(pr.pickup_recipient_phone, ''), '[^0-9]', '', 'g');

do $$
declare
  v_src bigint;
  v_tgt bigint;
begin
  -- (b) PU-2608-0006 → PU-2608-0005 병합
  --     0005는 2박스 신청인데 멀티박스 송장 버그로 1박스만 수거됐고,
  --     남은 박스를 위해 운영진이 0006을 임의 생성했다. 물리적으로는 한 건.
  select id into v_src from public.pickup_requests where request_number = 'PU-2608-0006';
  select id into v_tgt from public.pickup_requests where request_number = 'PU-2608-0005';

  if v_src is not null and v_tgt is not null then
    -- 양쪽에서 '상품 등록'을 눌러 생긴 빈 검수 건 정리 (#58 — 책 0권)
    delete from public.shipments s
    where s.pickup_request_id = v_src
      and not exists (select 1 from public.books b where b.shipment_id = s.id);

    update public.shipments
    set pickup_request_id = v_tgt
    where pickup_request_id = v_src;

    update public.pickup_requests
    set merged_into_id = v_tgt,
        updated_at = now()
    where id = v_src
      and merged_into_id is null;
  end if;

end $$;

-- (c) 브리지가 늦게 붙은 탓에 못 따라간 수거신청 상태를 전진 동기화.
--     (트리거는 shipments.status UPDATE에만 걸려 사후 브리지는 못 잡는다)
--     '검수완료'만 반영한다 — '검수중'은 건드리지 않는다. PU-2608-0005처럼 박스 하나가
--     아직 배송 중인데 신청 상태를 검수중으로 밀면 운영자가 남은 박스를 놓친다.
--     검수중→검수완료 전환은 기존 트리거가 잡는다.
update public.pickup_requests pr
set status = 'inspected', updated_at = now()
from public.shipments s
where s.pickup_request_id = pr.id
  and s.status = 'inspected'
  and pr.status in ('pending', 'pickup_scheduled', 'picking_up', 'arrived', 'inspecting');

commit;
