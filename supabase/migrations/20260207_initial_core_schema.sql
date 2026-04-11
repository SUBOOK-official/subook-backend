-- Baseline schema for local Supabase resets.
-- Earlier environments already had these core tables before the first tracked
-- migration. Keep this minimal so later migrations remain the source of truth
-- for storefront, member, order, and settlement extensions.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.shipments (
  id bigint generated always as identity primary key,
  seller_name text not null,
  seller_phone text not null,
  pickup_date date not null,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'inspected')),
  created_at timestamptz not null default now()
);

create table if not exists public.books (
  id bigint generated always as identity primary key,
  shipment_id bigint not null references public.shipments(id) on delete cascade,
  title text not null,
  status text not null default 'on_sale'
    check (status in ('on_sale', 'sold_out', 'settled')),
  price integer null check (price is null or price >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_shipments_seller_lookup
  on public.shipments (seller_name, seller_phone, created_at desc);

create index if not exists idx_books_shipment_id
  on public.books (shipment_id);

alter table public.shipments enable row level security;
alter table public.books enable row level security;
