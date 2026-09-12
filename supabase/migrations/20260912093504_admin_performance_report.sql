-- 성과 대시보드: 결제일(KST) 기준 실적과 직전 동일 길이 기간.
-- 주문/결제/환불 처리 함수와 RLS 정책은 변경하지 않는 읽기 전용 RPC.
-- 순매출은 해당 기간 결제 코호트의 현재 누적 환불 차감액(환불 처리일 기준 아님).
begin;

create function public.admin_performance_report(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
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

  with paid_orders as materialized (
    select o.id, o.user_id,
      (coalesce(o.paid_at, o.pg_approved_at) at time zone 'Asia/Seoul')::date as paid_date,
      o.total_amount::bigint as gross_revenue,
      case when o.payment_status = 'refunded' then o.total_amount
        else least(o.total_amount, coalesce(o.refunded_amount, 0)) end::bigint as refunds,
      o.payment_status,
      -- 회원은 계정, 비회원은 정규화한 주문 연락처. 식별자는 응답에 반환하지 않는다.
      case when o.user_id is not null then 'member:' || o.user_id::text
        else 'guest:' || coalesce(nullif(regexp_replace(o.shipping_recipient_phone, '[^0-9]', '', 'g'), ''), 'order:' || o.id::text)
      end as buyer_key,
      nullif(o.attribution #>> '{last_touch,source}', '') is not null as has_attribution,
      -- fbclid만으로 광고라고 단정하지 않는다. 유료 매체와 Meta 출처가 모두 있어야 한다.
      lower(coalesce(o.attribution #>> '{last_touch,source}', '')) = any(array['meta','facebook','instagram','ig','fb','threads','th'])
        and lower(coalesce(o.attribution #>> '{last_touch,medium}', '')) ~ '^(paid.*|.*cp.*|ppc|retargeting|display)$' as is_meta_paid,
      o.status = 'cancelled' and o.payment_status = 'paid' as cancelled_paid
    from public.orders o
    where o.payment_status in ('paid', 'refunded')
      -- 결제 시각이 없는 과거 취소 주문은 입금 여부가 불명확하므로 매출에 포함하지 않는다.
      and coalesce(o.paid_at, o.pg_approved_at) >= ((p_from - v_days)::timestamp at time zone 'Asia/Seoul')
      and coalesce(o.paid_at, o.pg_approved_at) < ((p_to + 1)::timestamp at time zone 'Asia/Seoul')
  ), item_totals as (
    select i.order_id, sum(i.quantity)::bigint as paid_quantity,
      sum(case when i.refunded_at is not null or o.payment_status = 'refunded' then i.quantity else 0 end)::bigint as refunded_quantity
    from public.order_items i join paid_orders o on o.id = i.order_id
    group by i.order_id
  ), facts as materialized (
    select o.*, coalesce(i.paid_quantity, 0) as paid_quantity,
      coalesce(i.refunded_quantity, 0) as refunded_quantity,
      coalesce(i.paid_quantity, 0) - coalesce(i.refunded_quantity, 0) as sold_quantity,
      o.gross_revenue - o.refunds as net_revenue
    from paid_orders o left join item_totals i on i.order_id = o.id
  ), periods as (
    select 'current'::text as key, p_from as from_date, p_to as to_date
    union all select 'previous', p_from - v_days, p_from - 1
  ), summaries as (
    select r.key, jsonb_build_object(
      'grossRevenue', coalesce(sum(f.gross_revenue), 0),
      'refunds', coalesce(sum(f.refunds), 0),
      'netRevenue', coalesce(sum(f.net_revenue), 0),
      'orders', count(f.id),
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
      coalesce(sum(f.sold_quantity), 0) as "soldQuantity",
      count(distinct f.buyer_key) as buyers,
      sum(f.gross_revenue)::numeric / nullif(count(f.id), 0) as aov
    from generate_series(0, v_days - 1) day_offset
    left join facts f on f.paid_date = p_from + day_offset
    group by day_offset
    order by day_offset
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'previousFrom', p_from - v_days, 'previousTo', p_from - 1,
    'timezone', 'Asia/Seoul', 'updatedAt', now(),
    'current', (select summary from summaries where key = 'current'),
    'previous', (select summary from summaries where key = 'previous'),
    'daily', (select jsonb_agg(to_jsonb(d) order by d.date) from daily d),
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
  '관리자 성과 지표. KST 결제일 기준, 순매출=기간 결제액-현재 누적 환불. 비회원 구매자는 주문 연락처로 중복 제거.';

commit;
-- Rollback: 이 migration이 추가한 admin_performance_report(date,date) 함수만 제거.
