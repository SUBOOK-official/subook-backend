-- 성과 조회만 확장한다. 주문/정산 생성·지급 및 기존 RLS는 변경하지 않는다.
-- 전일학원 50%는 2026-09-19 대표 요청의 보고용 정책이며 지급 로직과 분리한다.
begin;

create or replace function public.admin_performance_report(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer
set search_path = ''
set statement_timeout = '10s'
as $function$
declare
  v_days integer;
  v_result jsonb;
begin
  if not coalesce(public.is_admin_user(), false) then
    raise exception '관리자만 조회할 수 있습니다.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to
     or p_to > (now() at time zone 'Asia/Seoul')::date
     or p_from < date '2000-01-01' or p_to - p_from >= 366 then
    raise exception '오늘까지 최대 366일의 올바른 조회 기간을 선택해주세요.' using errcode = '22023';
  end if;
  v_days := p_to - p_from + 1;

  with payment_history as materialized (
    select o.id, coalesce(o.paid_at, o.pg_approved_at) as paid_time,
      case when o.user_id is not null then 'member:' || o.user_id::text
        else 'guest:' || coalesce(nullif(regexp_replace(o.shipping_recipient_phone, '[^0-9]', '', 'g'), ''), 'order:' || o.id::text)
      end as buyer_key
    from public.orders o
    where o.payment_status in ('paid', 'refunded')
      and coalesce(o.paid_at, o.pg_approved_at) < ((p_to + 1)::timestamp at time zone 'Asia/Seoul')
  ), ranked_payments as (
    -- 조회 시작일 전 이력도 포함. 같은 결제 시각은 주문 ID로 순서를 고정한다.
    select h.*, row_number() over (partition by buyer_key order by paid_time, id) > 1 as is_repeat
    from payment_history h
  ), paid_orders as materialized (
    select o.id, o.user_id, h.buyer_key, h.is_repeat,
      (h.paid_time at time zone 'Asia/Seoul')::date as paid_date,
      o.total_amount::bigint as gross_revenue,
      case when o.payment_status = 'refunded' then o.total_amount
        else least(o.total_amount, coalesce(o.refunded_amount, 0)) end::bigint as refunds,
      o.payment_status,
      nullif(o.attribution #>> '{last_touch,source}', '') is not null as has_attribution,
      lower(coalesce(o.attribution #>> '{last_touch,source}', '')) = any(array['meta','facebook','instagram','ig','fb','threads','th'])
        and lower(coalesce(o.attribution #>> '{last_touch,medium}', '')) ~ '^(paid.*|.*cp.*|ppc|retargeting|display)$' as is_meta_paid,
      o.status = 'cancelled' and o.payment_status = 'paid' as cancelled_paid
    from public.orders o join ranked_payments h on h.id = o.id
    where h.paid_time >= ((p_from - v_days)::timestamp at time zone 'Asia/Seoul')
  ), item_totals as (
    select i.order_id, sum(i.quantity)::bigint as paid_quantity,
      sum(case when i.refunded_at is not null or o.payment_status = 'refunded' then i.quantity else 0 end)::bigint as refunded_quantity
    from public.order_items i join paid_orders o on o.id = i.order_id
    group by i.order_id
  ), commission_items as materialized (
    select i.order_id, o.paid_date, i.quantity,
      coalesce(st.sale_amount, price.sale_amount) as sale_amount,
      case when st.id is not null then st.fee_percent
        when b.brand = '전일학원' then 50::numeric
        when s.id is not null and not coalesce(s.is_direct_purchase, false)
          then public.calculate_settlement_fee_percent(price.unit_price, s.pickup_date, s.fee_policy_version)
        else null end as fee_percent,
      st.fee_amount as recorded_fee,
      case when st.id is not null then 'settled'
        when b.brand = '전일학원' then 'jeonil'
        when s.id is not null and not coalesce(s.is_direct_purchase, false) then 'pickup'
        when s.is_direct_purchase then 'direct_purchase'
        else 'unknown' end as basis
    from public.order_items i join paid_orders o on o.id = i.order_id
    left join public.books b on b.id = i.book_id
    left join public.shipments s on s.id = b.shipment_id
    left join lateral (
      -- 저장된 정산 스냅샷이 있으면 현재 정책으로 재계산하지 않는다.
      select st.id, st.sale_amount, st.fee_percent, st.fee_amount
      from public.settlements st
      where st.order_id = i.order_id and st.book_id = i.book_id and st.status <> 'cancelled'
      order by st.id desc limit 1
    ) st on true
    cross join lateral (
      select greatest(0, coalesce(i.total_price, i.unit_price * greatest(1, coalesce(i.quantity, 1)), 0)) as sale_amount,
        greatest(0, coalesce(i.unit_price, case when i.quantity > 0 then floor(i.total_price::numeric / i.quantity)::integer else i.total_price end, 0)) as unit_price
    ) price
    where i.refunded_at is null and o.payment_status <> 'refunded'
  ), commission_facts as materialized (
    select c.*, coalesce(recorded_fee, round(sale_amount * fee_percent / 100)) as fee_amount
    from commission_items c where sale_amount > 0
  ), commission_totals as (
    select order_id,
      coalesce(sum(sale_amount) filter(where fee_percent is not null), 0) as commission_sales,
      coalesce(sum(fee_amount) filter(where fee_percent is not null), 0) as commission_amount,
      coalesce(sum(quantity) filter(where fee_percent is null), 0) as commission_excluded_quantity
    from commission_facts group by order_id
  ), facts as materialized (
    select o.*, coalesce(i.paid_quantity, 0) as paid_quantity,
      coalesce(i.refunded_quantity, 0) as refunded_quantity,
      coalesce(i.paid_quantity, 0) - coalesce(i.refunded_quantity, 0) as sold_quantity,
      o.gross_revenue - o.refunds as net_revenue,
      coalesce(c.commission_sales, 0) as commission_sales,
      coalesce(c.commission_amount, 0) as commission_amount,
      coalesce(c.commission_excluded_quantity, 0) as commission_excluded_quantity
    from paid_orders o left join item_totals i on i.order_id = o.id
    left join commission_totals c on c.order_id = o.id
  ), periods as (
    select 'current'::text as key, p_from as from_date, p_to as to_date
    union all select 'previous', p_from - v_days, p_from - 1
  ), summaries as (
    select r.key, jsonb_build_object(
      'grossRevenue', coalesce(sum(f.gross_revenue), 0),
      'refunds', coalesce(sum(f.refunds), 0),
      'netRevenue', coalesce(sum(f.net_revenue), 0),
      'orders', count(f.id),
      'repeatOrders', count(f.id) filter(where f.is_repeat),
      'repeatOrderRate', 100.0 * count(f.id) filter(where f.is_repeat) / nullif(count(f.id), 0),
      'commissionSales', coalesce(sum(f.commission_sales), 0),
      'commissionAmount', coalesce(sum(f.commission_amount), 0),
      'averageCommissionRate', 100.0 * sum(f.commission_amount) / nullif(sum(f.commission_sales), 0),
      'commissionExcludedQuantity', coalesce(sum(f.commission_excluded_quantity), 0),
      'soldQuantity', coalesce(sum(f.sold_quantity), 0),
      'paidQuantity', coalesce(sum(f.paid_quantity), 0),
      'refundedQuantity', coalesce(sum(f.refunded_quantity), 0),
      'buyers', count(distinct f.buyer_key),
      'guestOrders', count(f.id) filter(where f.user_id is null),
      'aov', sum(f.gross_revenue)::numeric / nullif(count(f.id), 0),
      'attributedOrders', count(f.id) filter(where f.has_attribution),
      'metaOrders', count(f.id) filter(where f.is_meta_paid and f.net_revenue > 0),
      'metaRevenue', coalesce(sum(f.net_revenue) filter(where f.is_meta_paid), 0),
      'cancelledPaidOrders', count(f.id) filter(where f.cancelled_paid)
    ) as summary
    from periods r left join facts f on f.paid_date between r.from_date and r.to_date
    group by r.key
  ), daily as (
    select p_from + day_offset as date,
      coalesce(sum(f.gross_revenue), 0) as "grossRevenue",
      coalesce(sum(f.refunds), 0) as refunds,
      coalesce(sum(f.net_revenue), 0) as "netRevenue",
      count(f.id) as orders,
      count(f.id) filter(where f.is_repeat) as "repeatOrders",
      100.0 * count(f.id) filter(where f.is_repeat) / nullif(count(f.id), 0) as "repeatOrderRate",
      coalesce(sum(f.commission_sales), 0) as "commissionSales",
      coalesce(sum(f.commission_amount), 0) as "commissionAmount",
      100.0 * sum(f.commission_amount) / nullif(sum(f.commission_sales), 0) as "averageCommissionRate",
      coalesce(sum(f.sold_quantity), 0) as "soldQuantity",
      count(distinct f.buyer_key) as buyers,
      sum(f.gross_revenue)::numeric / nullif(count(f.id), 0) as aov
    from generate_series(0, v_days - 1) day_offset
    left join facts f on f.paid_date = p_from + day_offset
    group by day_offset order by day_offset
  ), commission_breakdown as (
    select basis, fee_percent as "feePercent", sum(quantity) as quantity,
      sum(sale_amount) as "saleAmount", sum(fee_amount) as "feeAmount"
    from commission_facts where paid_date between p_from and p_to
    group by basis, fee_percent
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'previousFrom', p_from - v_days, 'previousTo', p_from - 1,
    'timezone', 'Asia/Seoul', 'updatedAt', now(),
    'current', (select summary from summaries where key = 'current'),
    'previous', (select summary from summaries where key = 'previous'),
    'daily', (select jsonb_agg(to_jsonb(d) order by d.date) from daily d),
    'commissionBreakdown', (select coalesce(jsonb_agg(to_jsonb(c) order by c.basis, c."feePercent"), '[]'::jsonb) from commission_breakdown c),
    'unverifiedPayments', (select count(*) from public.orders o
      where o.payment_status in ('paid', 'refunded') and coalesce(o.paid_at, o.pg_approved_at) is null
        and o.created_at >= (p_from::timestamp at time zone 'Asia/Seoul')
        and o.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Seoul'))
  ) into v_result;
  return v_result;
end;
$function$;

revoke all on function public.admin_performance_report(date, date) from public, anon;
grant execute on function public.admin_performance_report(date, date) to authenticated;
comment on function public.admin_performance_report(date, date) is
  '관리자 KST 결제일 성과. 재구매=과거 결제 이력 보유 주문/전체 결제 주문. 수수료=미환불 상품의 저장 정산 또는 수거 정책 및 전일 50%를 판매금액 가중 평균.';

commit;
-- Rollback: 20260912093504의 함수 정의를 CREATE OR REPLACE로 복원. 데이터 변경 없음.
