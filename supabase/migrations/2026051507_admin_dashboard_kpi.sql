-- 어드민 대시보드 KPI/분석 RPC 5종 (P3 Sprint 2-1)
--
-- 1. admin_dashboard_kpi(p_from, p_to)         — 핵심 KPI 단일 row
-- 2. admin_dashboard_revenue_series(p_days)    — 일별 매출 시계열
-- 3. admin_dashboard_top_sellers(p_limit, ...) — 상위 셀러
-- 4. admin_dashboard_top_products(p_limit,...) — 인기 상품
-- 5. admin_dashboard_subject_breakdown(...)    — 과목별 매출 비율
--
-- 모두 SECURITY DEFINER + is_admin_user() 가드.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 핵심 KPI: 매출/주문/검수/정산 합계
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_dashboard_kpi(
  p_from date default current_date - 29,
  p_to date default current_date
)
returns table (
  range_from date,
  range_to date,
  revenue_total bigint,
  confirmed_revenue bigint,
  pending_settlement_amount bigint,
  completed_settlement_amount bigint,
  order_count bigint,
  paid_order_count bigint,
  confirmed_order_count bigint,
  cancelled_order_count bigint,
  refunded_order_count bigint,
  inspection_processed_count bigint,
  settled_book_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p_from,
    p_to,
    coalesce((
      select sum(o.total_amount)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
        and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
    ), 0) as revenue_total,
    coalesce((
      select sum(o.total_amount)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
        and o.status = 'confirmed'
    ), 0) as confirmed_revenue,
    coalesce((
      select sum(s.net_amount)::bigint
      from public.settlements s
      where s.status in ('pending', 'approved')
    ), 0) as pending_settlement_amount,
    coalesce((
      select sum(s.net_amount)::bigint
      from public.settlements s
      where s.status = 'completed'
        and s.completed_at::date between p_from and p_to
    ), 0) as completed_settlement_amount,
    coalesce((
      select count(*)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
    ), 0) as order_count,
    coalesce((
      select count(*)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
        and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
    ), 0) as paid_order_count,
    coalesce((
      select count(*)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
        and o.status = 'confirmed'
    ), 0) as confirmed_order_count,
    coalesce((
      select count(*)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
        and o.status = 'cancelled'
    ), 0) as cancelled_order_count,
    coalesce((
      select count(*)::bigint
      from public.orders o
      where o.created_at::date between p_from and p_to
        and o.status = 'refunded'
    ), 0) as refunded_order_count,
    coalesce((
      select count(*)::bigint
      from public.books b
      where b.inspected_at is not null
        and b.inspected_at::date between p_from and p_to
    ), 0) as inspection_processed_count,
    coalesce((
      select count(*)::bigint
      from public.books b
      where b.status = 'settled'
    ), 0) as settled_book_count
  where public.is_admin_user();
$$;

grant execute on function public.admin_dashboard_kpi(date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 일별 매출 시계열 (generate_series로 빈 날짜도 0으로 채움)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_dashboard_revenue_series(
  p_days integer default 30
)
returns table (
  bucket_date date,
  paid_amount bigint,
  confirmed_amount bigint,
  order_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    d::date as bucket_date,
    coalesce(sum(case
      when o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
        then o.total_amount else 0 end), 0)::bigint as paid_amount,
    coalesce(sum(case
      when o.status = 'confirmed' then o.total_amount else 0 end), 0)::bigint as confirmed_amount,
    count(o.id)::bigint as order_count
  from generate_series(
    current_date - (greatest(p_days, 1) - 1),
    current_date,
    interval '1 day'
  ) d
  left join public.orders o
    on o.created_at::date = d::date
  where public.is_admin_user()
  group by d::date
  order by d::date;
$$;

grant execute on function public.admin_dashboard_revenue_series(integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 상위 셀러 (정산 net_amount 기준)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_dashboard_top_sellers(
  p_limit integer default 10,
  p_from date default current_date - 29,
  p_to date default current_date
)
returns table (
  seller_user_id uuid,
  seller_name text,
  seller_email text,
  total_net_amount bigint,
  settlement_count bigint,
  book_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.seller_user_id,
    coalesce(mp.name, mp.nickname, 'Unknown') as seller_name,
    mp.email as seller_email,
    sum(s.net_amount)::bigint as total_net_amount,
    count(distinct s.id)::bigint as settlement_count,
    count(distinct s.book_id)::bigint as book_count
  from public.settlements s
  left join public.member_profiles mp on mp.user_id = s.seller_user_id
  where public.is_admin_user()
    and s.seller_user_id is not null
    and s.status in ('approved', 'completed')
    and s.scheduled_date between p_from and p_to
  group by s.seller_user_id, mp.name, mp.nickname, mp.email
  order by total_net_amount desc
  limit greatest(p_limit, 1);
$$;

grant execute on function public.admin_dashboard_top_sellers(integer, date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 인기 상품 (주문 빈도 + 매출 기준)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_dashboard_top_products(
  p_limit integer default 10,
  p_from date default current_date - 29,
  p_to date default current_date
)
returns table (
  product_id bigint,
  product_title text,
  product_subject text,
  product_brand text,
  order_count bigint,
  sold_quantity bigint,
  total_sales bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id as product_id,
    p.title as product_title,
    p.subject as product_subject,
    p.brand as product_brand,
    count(distinct oi.order_id)::bigint as order_count,
    sum(oi.quantity)::bigint as sold_quantity,
    sum(oi.total_price)::bigint as total_sales
  from public.order_items oi
  inner join public.orders o on o.id = oi.order_id
  inner join public.products p on p.id = oi.product_id
  where public.is_admin_user()
    and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
    and o.created_at::date between p_from and p_to
    and oi.product_id is not null
  group by p.id, p.title, p.subject, p.brand
  order by total_sales desc nulls last, order_count desc
  limit greatest(p_limit, 1);
$$;

grant execute on function public.admin_dashboard_top_products(integer, date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) 과목별 매출 비율
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_dashboard_subject_breakdown(
  p_from date default current_date - 29,
  p_to date default current_date
)
returns table (
  subject text,
  order_count bigint,
  total_sales bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(b.subject, '기타') as subject,
    count(distinct oi.order_id)::bigint as order_count,
    sum(oi.total_price)::bigint as total_sales
  from public.order_items oi
  inner join public.orders o on o.id = oi.order_id
  left join public.books b on b.id = oi.book_id
  where public.is_admin_user()
    and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
    and o.created_at::date between p_from and p_to
  group by coalesce(b.subject, '기타')
  order by sum(oi.total_price) desc nulls last;
$$;

grant execute on function public.admin_dashboard_subject_breakdown(date, date) to authenticated;

commit;
