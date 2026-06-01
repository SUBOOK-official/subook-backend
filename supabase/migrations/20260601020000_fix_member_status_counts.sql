-- 회원 상태 필터칩 카운트 버그 수정.
--
-- 버그: 20260601010000에서 상태 필터(p_status)를 members CTE의 WHERE에 넣어,
--   enriched가 '이미 필터된 집합'이 되었다. 그런데 summary의 상태별 카운트도
--   enriched 기준이라, '차단' 필터를 누르면 차단 회원만 남은 집합에서 카운트가
--   계산돼 칩이 1-0-1-0-0 처럼 보였다. 칩 카운트는 상태 필터와 무관하게 전체
--   분포(검색 집합 기준)를 보여줘야 한다.
--
-- 수정: 상태 필터를 members/enriched 단계에서 분리한다.
--   - members(검색만) → enriched(통계 join, 상태필터 없음): 칩 카운트·전체 분포 기준.
--   - visible(enriched에서 p_status 적용): 실제 목록 rows·total_count 기준.
--   summary 상태별 카운트는 enriched(필터 미적용) 기준이라 항상 안정적.
--
-- 반환 키·구조는 동일 → 프론트 변경 불필요.

begin;

create or replace function public.list_admin_members(
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits,
      nullif(btrim(coalesce(p_status, '')), '') as status_filter
  ),
  members as (
    select
      mp.user_id,
      mp.email,
      mp.name,
      mp.nickname,
      coalesce(nullif(btrim(mp.nickname), ''), nullif(btrim(mp.name), ''), mp.email) as display_name,
      mp.phone,
      coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
      mp.email_verified_at,
      coalesce(au.created_at, mp.created_at) as joined_at,
      mp.created_at,
      mp.updated_at,
      coalesce(mp.is_blocked, false) as is_blocked,
      mp.blocked_at,
      mp.block_reason,
      mp.withdrawal_requested_at,
      mp.personal_data_erased_at,
      -- 단일 상태값으로 정규화 (우선순위: 탈퇴완료 > 탈퇴대기 > 차단 > 정상)
      case
        when mp.personal_data_erased_at is not null then 'withdrawn'
        when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
        when coalesce(mp.is_blocked, false) then 'blocked'
        else 'active'
      end as account_status
    from public.member_profiles mp
    left join auth.users au
      on au.id = mp.user_id
    cross join params
    where not exists (
        select 1
        from public.admin_users admin_user
        where lower(admin_user.email) = lower(mp.email)
      )
      and (
        params.search_term = ''
        or mp.name ilike '%' || params.search_term || '%'
        or coalesce(mp.nickname, '') ilike '%' || params.search_term || '%'
        or mp.email ilike '%' || params.search_term || '%'
        or coalesce(mp.phone, '') ilike '%' || params.search_term || '%'
        or (
          params.search_digits <> ''
          and regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') like '%' || params.search_digits || '%'
        )
      )
    -- ⚠ 상태 필터는 여기서 적용하지 않는다. (칩 카운트가 전체 분포를 보여줘야 하므로)
  ),
  enriched as (
    select
      m.*,
      coalesce(pickup_stats.pickup_request_count, 0) as pickup_request_count,
      coalesce(pickup_stats.pickup_item_count, 0) as pickup_request_item_count,
      coalesce(shipment_stats.legacy_shipment_count, 0) as legacy_shipment_count,
      coalesce(shipment_stats.legacy_book_count, 0) as legacy_book_count,
      coalesce(order_stats.order_count, 0) as order_count,
      coalesce(order_stats.purchase_amount, 0) as purchase_amount,
      coalesce(settlement_stats.settlement_count, 0) as settlement_count,
      coalesce(settlement_stats.sale_amount, 0) + coalesce(legacy_sale_stats.sale_amount, 0) as sale_amount,
      coalesce(settlement_stats.net_amount, 0) as net_settlement_amount,
      greatest(
        coalesce(pickup_stats.latest_pickup_at, 'epoch'::timestamptz),
        coalesce(shipment_stats.latest_shipment_at, 'epoch'::timestamptz),
        coalesce(order_stats.latest_order_at, 'epoch'::timestamptz),
        coalesce(settlement_stats.latest_settlement_at, 'epoch'::timestamptz)
      ) as latest_activity_at
    from members m
    left join lateral (
      select
        count(*)::integer as pickup_request_count,
        coalesce(sum(pr.item_count), 0)::integer as pickup_item_count,
        max(pr.created_at) as latest_pickup_at
      from public.pickup_requests pr
      where pr.user_id = m.user_id
    ) pickup_stats on true
    left join lateral (
      select
        count(distinct s.id)::integer as legacy_shipment_count,
        count(b.id)::integer as legacy_book_count,
        max(s.created_at) as latest_shipment_at
      from public.shipments s
      left join public.books b
        on b.shipment_id = s.id
      where s.user_id = m.user_id
    ) shipment_stats on true
    left join lateral (
      select
        count(*)::integer as order_count,
        coalesce(sum(o.total_amount) filter (where o.status not in ('cancelled', 'refunded')), 0)::integer as purchase_amount,
        max(o.created_at) as latest_order_at
      from public.orders o
      where o.user_id = m.user_id
    ) order_stats on true
    left join lateral (
      select
        count(*)::integer as settlement_count,
        coalesce(sum(st.sale_amount), 0)::integer as sale_amount,
        coalesce(sum(st.net_amount), 0)::integer as net_amount,
        max(coalesce(st.completed_at, st.approved_at, st.created_at)) as latest_settlement_at
      from public.settlements st
      where st.seller_user_id = m.user_id
    ) settlement_stats on true
    left join lateral (
      select
        coalesce(sum(b.price), 0)::integer as sale_amount
      from public.shipments s
      join public.books b
        on b.shipment_id = s.id
      where s.user_id = m.user_id
        and b.status = 'settled'
        and not exists (
          select 1
          from public.settlements st
          where st.book_id = b.id
        )
    ) legacy_sale_stats on true
  ),
  -- 상태 필터는 여기서만 적용 → 실제 목록·total_count 기준.
  visible as (
    select e.*
    from enriched e
    cross join params
    where params.status_filter is null
      or params.status_filter = 'all'
      or e.account_status = params.status_filter
  ),
  page_rows as (
    select *
    from visible
    order by joined_at desc, user_id
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'user_id', row_data.user_id,
              'email', row_data.email,
              'name', row_data.name,
              'nickname', row_data.nickname,
              'display_name', row_data.display_name,
              'phone', row_data.phone,
              'marketing_opt_in', row_data.marketing_opt_in,
              'email_verified_at', row_data.email_verified_at,
              'joined_at', row_data.joined_at,
              'created_at', row_data.created_at,
              'updated_at', row_data.updated_at,
              'is_blocked', row_data.is_blocked,
              'blocked_at', row_data.blocked_at,
              'block_reason', row_data.block_reason,
              'withdrawal_requested_at', row_data.withdrawal_requested_at,
              'personal_data_erased_at', row_data.personal_data_erased_at,
              'account_status', row_data.account_status,
              'pickup_count', row_data.pickup_request_count + row_data.legacy_shipment_count,
              'pickup_item_count', row_data.pickup_request_item_count + row_data.legacy_book_count,
              'order_count', row_data.order_count,
              'purchase_amount', row_data.purchase_amount,
              'settlement_count', row_data.settlement_count,
              'sale_amount', row_data.sale_amount,
              'net_settlement_amount', row_data.net_settlement_amount,
              'latest_activity_at', nullif(row_data.latest_activity_at, 'epoch'::timestamptz)
            )
            order by row_data.joined_at desc, row_data.user_id
          )
          from page_rows row_data
        ),
        '[]'::jsonb
      ),
    -- 목록 페이지네이션 기준: 상태 필터 적용된 visible
    'total_count', (select count(*) from visible),
    'summary',
      jsonb_build_object(
        -- 상태별 카운트·전체 분포: 상태 필터 미적용 enriched 기준(항상 안정)
        'member_count', (select count(*) from enriched),
        'new_member_count_30d', (
          select count(*)
          from enriched
          where joined_at >= now() - interval '30 days'
        ),
        'purchase_amount', coalesce((select sum(purchase_amount) from enriched), 0),
        'sale_amount', coalesce((select sum(sale_amount) from enriched), 0),
        'pickup_count', coalesce((select sum(pickup_request_count + legacy_shipment_count) from enriched), 0),
        'order_count', coalesce((select sum(order_count) from enriched), 0),
        'active_count', (select count(*) from enriched where account_status = 'active'),
        'blocked_count', (select count(*) from enriched where account_status = 'blocked'),
        'withdrawal_pending_count', (select count(*) from enriched where account_status = 'withdrawal_pending'),
        'withdrawn_count', (select count(*) from enriched where account_status = 'withdrawn')
      )
  )
  into v_result;

  return v_result;
end;
$$;

commit;
