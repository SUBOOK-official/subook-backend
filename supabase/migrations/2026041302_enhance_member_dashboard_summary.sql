drop function if exists public.get_member_dashboard_summary();

create or replace function public.get_member_dashboard_summary()
returns table (
  user_id uuid,
  email text,
  name text,
  nickname text,
  display_name text,
  phone text,
  marketing_opt_in boolean,
  shipping_address_count integer,
  default_shipping_address_id bigint,
  settlement_account_count integer,
  default_settlement_account_id bigint,
  shipment_count integer,
  recent_shipment_count integer,
  total_book_count integer,
  on_sale_book_count integer,
  settled_book_count integer,
  estimated_on_sale_value integer,
  estimated_settled_value integer,
  latest_shipment_created_at timestamptz,
  latest_shipment_pickup_date date,
  latest_shipment_status text,
  purchase_in_progress_count integer,
  current_month_settlement_total integer,
  total_settlement_amount integer
)
language sql
stable
security definer
set search_path = public
as $$
  with member as (
    select
      mp.user_id,
      mp.email,
      mp.name,
      mp.nickname,
      mp.phone,
      mp.marketing_opt_in
    from public.member_profiles mp
    where mp.user_id = auth.uid()
  ),
  address_stats as (
    select
      count(*)::integer as shipping_address_count,
      max(id) filter (where is_default) as default_shipping_address_id
    from public.member_shipping_addresses
    where user_id = auth.uid()
  ),
  account_stats as (
    select
      count(*)::integer as settlement_account_count,
      max(id) filter (where is_default) as default_settlement_account_id
    from public.member_settlement_accounts
    where user_id = auth.uid()
  ),
  pickup_request_stats as (
    select
      count(*)::integer as shipment_count,
      count(*) filter (where pr.created_at >= now() - interval '30 days')::integer as recent_shipment_count,
      max(pr.created_at) as latest_shipment_created_at,
      max(pr.created_at)::date as latest_shipment_pickup_date,
      (array_agg(pr.status order by pr.created_at desc, pr.id desc))[1] as latest_shipment_status
    from public.pickup_requests pr
    where pr.user_id = auth.uid()
  ),
  legacy_shipment_stats as (
    select
      count(*)::integer as shipment_count,
      count(*) filter (where s.created_at >= now() - interval '30 days')::integer as recent_shipment_count,
      max(s.created_at) as latest_shipment_created_at,
      (array_agg(s.pickup_date order by s.created_at desc, s.id desc))[1] as latest_shipment_pickup_date,
      (array_agg(s.status order by s.created_at desc, s.id desc))[1] as latest_shipment_status
    from public.shipments s
    where s.user_id = auth.uid()
  ),
  shipment_stats as (
    select
      case
        when pickup_request_stats.shipment_count > 0 then pickup_request_stats.shipment_count
        else legacy_shipment_stats.shipment_count
      end as shipment_count,
      case
        when pickup_request_stats.shipment_count > 0 then pickup_request_stats.recent_shipment_count
        else legacy_shipment_stats.recent_shipment_count
      end as recent_shipment_count,
      coalesce(
        pickup_request_stats.latest_shipment_created_at,
        legacy_shipment_stats.latest_shipment_created_at
      ) as latest_shipment_created_at,
      coalesce(
        pickup_request_stats.latest_shipment_pickup_date,
        legacy_shipment_stats.latest_shipment_pickup_date
      ) as latest_shipment_pickup_date,
      coalesce(
        pickup_request_stats.latest_shipment_status,
        legacy_shipment_stats.latest_shipment_status
      ) as latest_shipment_status
    from pickup_request_stats
    cross join legacy_shipment_stats
  ),
  inventory_stats as (
    select
      count(b.id)::integer as total_book_count,
      count(*) filter (where b.status = 'on_sale')::integer as on_sale_book_count,
      count(*) filter (where b.status = 'settled')::integer as settled_book_count,
      coalesce(sum(b.price) filter (where b.status = 'on_sale'), 0)::integer as estimated_on_sale_value
    from public.books b
    join public.shipments s
      on s.id = b.shipment_id
    where s.user_id = auth.uid()
  ),
  purchase_stats as (
    select
      count(*) filter (where o.status in ('pending', 'paid', 'shipping', 'delivered'))::integer
        as purchase_in_progress_count
    from public.orders o
    where o.user_id = auth.uid()
  ),
  settlement_stats as (
    select
      coalesce(sum(st.net_amount) filter (
        where st.status = 'completed'
          and st.completed_at >= date_trunc('month', now())
      ), 0)::integer as current_month_settlement_total,
      coalesce(sum(st.net_amount) filter (where st.status = 'completed'), 0)::integer
        as total_settlement_amount,
      coalesce(sum(st.net_amount) filter (where st.status in ('pending', 'approved')), 0)::integer
        as estimated_settled_value
    from public.settlements st
    where st.seller_user_id = auth.uid()
  )
  select
    member.user_id,
    member.email,
    member.name,
    member.nickname,
    coalesce(
      nullif(btrim(member.nickname), ''),
      nullif(btrim(member.name), ''),
      split_part(member.email, '@', 1),
      '회원'
    ) as display_name,
    member.phone,
    member.marketing_opt_in,
    address_stats.shipping_address_count,
    address_stats.default_shipping_address_id,
    account_stats.settlement_account_count,
    account_stats.default_settlement_account_id,
    shipment_stats.shipment_count,
    shipment_stats.recent_shipment_count,
    inventory_stats.total_book_count,
    inventory_stats.on_sale_book_count,
    inventory_stats.settled_book_count,
    inventory_stats.estimated_on_sale_value,
    settlement_stats.estimated_settled_value,
    shipment_stats.latest_shipment_created_at,
    shipment_stats.latest_shipment_pickup_date,
    shipment_stats.latest_shipment_status,
    purchase_stats.purchase_in_progress_count,
    settlement_stats.current_month_settlement_total,
    settlement_stats.total_settlement_amount
  from member
  cross join address_stats
  cross join account_stats
  cross join shipment_stats
  cross join inventory_stats
  cross join purchase_stats
  cross join settlement_stats;
$$;

grant execute on function public.get_member_dashboard_summary() to authenticated;
