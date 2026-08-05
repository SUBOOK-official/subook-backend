-- 레거시 셀러(구 수북/식스샵 시절) 판매·정산 이력 마이페이지 노출
--
-- 배경: 신규 수거신청 플로우(pickup_requests) 도입 전에 수거된 shipment는
--   pickup_request_id가 없어 get_my_pickup_requests에 잡히지 않았고,
--   마이페이지 판매 탭은 집계 전용 fallback 행을 그대로 렌더하다 크래시했다
--   (오지민 셀러 문의, 2026-08-05). 같은 셀러들의 식스샵 시절 지급 이력도
--   manual_settlements에만 있어 정산 탭이 비어 보였다.
--
-- 1) get_my_pickup_requests: 본인 소유(user_id) + 수거신청 미연결 shipment를
--    같은 행 형태(검수 books = items)로 UNION해 반환. id는 'legacy-<shipment_id>'
--    문자열로 신청 id와 충돌 방지, status는 프론트가 아는 수거신청 어휘로 번역.
-- 2) get_my_settlements: manual_settlements(전부 shipment_id 보유)를 shipment
--    소유자 기준으로 완료 정산 행으로 UNION하고 합계(summary)에도 포함.
--    paid → completed 매핑, 계좌 정보는 미보관이라 null.

create or replace function public.get_my_pickup_requests(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
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
      -- 신규 플로우: 수거신청 기반 (기존 동작 유지)
      select
        jsonb_build_object(
          'id', pr.id,
          'source', 'pickup_request',
          'request_number', pr.request_number,
          'status', pr.status,
          'item_count', pr.item_count,
          'box_count', pr.box_count,
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
            -- 1순위: 브리지된 shipment의 실제 검수 books (등급·확정가·폐기사유·검수사진)
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
              where s.pickup_request_id = pr.id
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

create or replace function public.get_my_settlements(
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  with platform_rows as (
    select
      st.*,
      o.order_number,
      o.created_at as sold_at,
      o.confirmed_at as order_confirmed_at,
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.quantity, 1) as quantity,
      b.shipment_id,
      pr.request_number as pickup_request_number
    from public.settlements st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.pickup_requests pr
      on pr.id = sh.pickup_request_id
    where st.seller_user_id = v_user_id
  ),
  -- 구 수북(식스샵) 판매분 수동정산 — shipment 소유자 기준으로 본인 것만
  manual_rows as (
    select
      ms.id,
      ms.book_id,
      b.title as book_title,
      b.option as book_option,
      ms.shipment_id,
      ms.sale_amount,
      ms.fee_percent,
      ms.fee_amount,
      ms.net_amount,
      case when ms.status = 'paid' then 'completed' else 'pending' end as status,
      ms.paid_at,
      ms.sold_at,
      ms.created_at
    from public.manual_settlements ms
    join public.shipments s
      on s.id = ms.shipment_id
    left join public.books b
      on b.id = ms.book_id
    where s.user_id = v_user_id
  ),
  combined as (
    select
      jsonb_build_object(
        'id', row_data.id,
        'source', 'platform',
        'order_id', row_data.order_id,
        'order_number', row_data.order_number,
        'book_id', row_data.book_id,
        'book_title', row_data.book_title,
        'book_option', row_data.book_option,
        'book_count', greatest(1, coalesce(row_data.quantity, 1)),
        -- 셀러가 아는 요청번호(PU-xxxx) 우선, 브리지 안 된 레거시는 shipment_id 유지
        'pickup_reference', coalesce(row_data.pickup_request_number, row_data.shipment_id::text),
        'sale_amount', row_data.sale_amount,
        'fee_percent', row_data.fee_percent,
        'fee_amount', row_data.fee_amount,
        'box_cost_deducted', coalesce(row_data.box_cost_deducted, 0),
        'net_amount', row_data.net_amount,
        'status', row_data.status,
        'scheduled_date', row_data.scheduled_date,
        'approved_at', row_data.approved_at,
        'completed_at', row_data.completed_at,
        'sold_at', row_data.sold_at,
        'confirmed_at', row_data.order_confirmed_at,
        'bank_name', row_data.bank_name,
        'account_number', public.mask_account_number(coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number))),
        'account_holder', row_data.account_holder,
        'account_last4', coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number)),
        'created_at', row_data.created_at
      ) as row_json,
      case row_data.status when 'completed' then 1 when 'approved' then 2 else 3 end as status_rank,
      coalesce(row_data.completed_at, row_data.scheduled_date::timestamptz, row_data.created_at) as sort_ts,
      row_data.id::text as sort_id
    from platform_rows row_data

    union all

    select
      jsonb_build_object(
        'id', 'manual-' || mr.id::text,
        'source', 'manual',
        'order_id', null,
        'order_number', null,
        'book_id', mr.book_id,
        'book_title', mr.book_title,
        'book_option', mr.book_option,
        'book_count', 1,
        'pickup_reference', mr.shipment_id::text,
        'sale_amount', mr.sale_amount,
        'fee_percent', mr.fee_percent,
        'fee_amount', mr.fee_amount,
        'box_cost_deducted', 0,
        'net_amount', mr.net_amount,
        'status', mr.status,
        'scheduled_date', null,
        'approved_at', null,
        'completed_at', mr.paid_at,
        'sold_at', mr.sold_at,
        'confirmed_at', null,
        'bank_name', null,
        'account_number', null,
        'account_holder', null,
        'account_last4', null,
        'created_at', mr.created_at
      ) as row_json,
      case mr.status when 'completed' then 1 else 3 end as status_rank,
      coalesce(mr.paid_at, mr.created_at) as sort_ts,
      'manual-' || mr.id::text as sort_id
    from manual_rows mr
  ),
  all_my_settlements as (
    select status, net_amount, completed_at
    from public.settlements
    where seller_user_id = v_user_id
    union all
    select status, net_amount, paid_at as completed_at
    from manual_rows
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(page.row_json order by page.status_rank, page.sort_ts desc nulls last, page.sort_id desc)
          from (
            select row_json, status_rank, sort_ts, sort_id
            from combined
            order by status_rank, sort_ts desc nulls last, sort_id desc
            offset greatest(0, coalesce(p_offset, 0))
            limit greatest(1, least(coalesce(p_limit, 50), 200))
          ) page
        ),
        '[]'::jsonb
      ),
    'summary',
      jsonb_build_object(
        'current_month_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status = 'completed'
              and completed_at >= date_trunc('month', now())
          ), 0),
        'total_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status = 'completed'
          ), 0),
        'expected_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status in ('pending', 'approved')
          ), 0),
        'pending_count',
          (select count(*) from all_my_settlements where status = 'pending'),
        'approved_count',
          (select count(*) from all_my_settlements where status = 'approved'),
        'completed_count',
          (select count(*) from all_my_settlements where status = 'completed')
      )
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_my_settlements(integer, integer) to authenticated;
