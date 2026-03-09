create or replace function public.lookup_seller_shipment(
  p_seller_name text,
  p_seller_phone text
)
returns table (
  id bigint,
  seller_name text,
  seller_phone text,
  pickup_date date,
  status text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    s.id,
    s.seller_name,
    s.seller_phone,
    s.pickup_date,
    s.status,
    s.created_at
  from public.shipments s
  where s.seller_name = btrim(coalesce(p_seller_name, ''))
    and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
      regexp_replace(btrim(coalesce(p_seller_phone, '')), '[^0-9]', '', 'g')
  order by s.created_at desc
  limit 1;
$$;

create or replace function public.lookup_seller_books(
  p_shipment_id bigint,
  p_seller_name text,
  p_seller_phone text
)
returns table (
  id bigint,
  shipment_id bigint,
  title text,
  option text,
  status text,
  price integer,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    b.id,
    b.shipment_id,
    b.title,
    b.option,
    b.status,
    b.price,
    b.created_at
  from public.books b
  join public.shipments s
    on s.id = b.shipment_id
  where b.shipment_id = p_shipment_id
    and s.seller_name = btrim(coalesce(p_seller_name, ''))
    and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
      regexp_replace(btrim(coalesce(p_seller_phone, '')), '[^0-9]', '', 'g')
  order by b.created_at asc;
$$;
