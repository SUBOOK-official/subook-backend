-- 병합 신청의 박스 수 합산 철회 (2026-08-10)
--
-- 20260810093100에서 병합된 자식 신청의 box_count를 원본에 더했는데 이중 계산이었다.
-- 실측: PU-2608-0005(2박스 신청) + PU-2608-0006(1박스) = 3박스로 표시됐지만
-- 실제로 셀러가 보낸 건 2박스다. 0006은 "새로 추가된 화물"이 아니라 송장 누락으로
-- 못 가져온 0005의 박스2를 다시 접수한 것이라, 원본 box_count에 이미 포함돼 있다.
--
-- 병합 = "하나의 물리적 수거가 여러 신청으로 쪼개진 것"이므로 원본의 box_count가
-- 그 수거 전체의 박스 수다. 자식 것을 더하면 안 된다.
-- 셀러가 진짜로 짐을 추가한 경우에는 운영자가 원본 box_count를 직접 올린다.
-- (merged_request_numbers로 어떤 신청이 합쳐졌는지는 계속 보인다)

begin;

-- 1) 셀러 마이페이지 — box_count 합산 제거
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
          -- 원본의 박스 수 = 이 수거 전체의 박스 수 (자식 것을 더하면 이중 계산)
          'box_count', pr.box_count,
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

-- 2) 위저드 통합 검색 — box_count 합산 제거
create or replace function public.admin_search_register_targets(
  p_search text default null,
  p_limit integer default 20
)
returns table (
  kind text,
  ref_id bigint,
  request_number text,
  seller_name text,
  seller_phone text,
  target_date date,
  status text,
  book_count integer,
  expected_book_count integer,
  box_count integer,
  user_id uuid,
  member_name text,
  sort_ts timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      btrim(coalesce(p_search, '')) as term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as digits
  )
  select * from (
    -- 진행 중인 회원 수거신청 (이 행을 고르면 프론트가 브리지 RPC를 태운다)
    select
      'pickup_request'::text as kind,
      pr.id as ref_id,
      pr.request_number,
      pr.pickup_recipient_name as seller_name,
      pr.pickup_recipient_phone as seller_phone,
      pr.desired_pickup_date as target_date,
      pr.status,
      coalesce((
        select count(*)::integer
        from public.books b
        join public.shipments s on s.id = b.shipment_id
        where s.pickup_request_id in (
          select c.id from public.pickup_requests c
          where c.id = pr.id or c.merged_into_id = pr.id
        )
      ), 0) as book_count,
      pr.expected_book_count,
      pr.box_count,
      pr.user_id,
      mp.name as member_name,
      pr.created_at as sort_ts
    from public.pickup_requests pr
    cross join params
    left join public.member_profiles mp on mp.user_id = pr.user_id
    where public.is_admin_user()
      and pr.status <> 'cancelled'
      and pr.merged_into_id is null
      and (
        params.term = ''
        or pr.pickup_recipient_name ilike '%' || params.term || '%'
        or pr.pickup_recipient_phone ilike '%' || params.term || '%'
        or pr.request_number ilike '%' || params.term || '%'
        or (
          params.digits <> ''
          and regexp_replace(pr.pickup_recipient_phone, '[^0-9]', '', 'g') like '%' || params.digits || '%'
        )
      )

    union all

    -- 직접입고·레거시 검수 건 (수거신청에 안 붙은 것만 — 붙은 건 위쪽에서 이미 나온다)
    select
      'shipment'::text as kind,
      s.id as ref_id,
      null::text as request_number,
      s.seller_name,
      s.seller_phone,
      s.pickup_date as target_date,
      s.status,
      coalesce((
        select count(*)::integer from public.books b where b.shipment_id = s.id
      ), 0) as book_count,
      null::integer as expected_book_count,
      s.box_count,
      s.user_id,
      mp.name as member_name,
      s.created_at as sort_ts
    from public.shipments s
    cross join params
    left join public.member_profiles mp on mp.user_id = s.user_id
    where public.is_admin_user()
      and s.pickup_request_id is null
      and (
        params.term = ''
        or s.seller_name ilike '%' || params.term || '%'
        or s.seller_phone ilike '%' || params.term || '%'
        or (
          params.digits <> ''
          and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') like '%' || params.digits || '%'
        )
      )
  ) merged
  order by sort_ts desc
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

grant execute on function public.admin_search_register_targets(text, integer) to authenticated;

commit;
