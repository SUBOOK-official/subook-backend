-- 장바구니
create table if not exists public.cart_items (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id bigint not null references public.books(id) on delete cascade,
  product_id bigint null references public.products(id) on delete set null,
  quantity integer not null default 1 check (quantity >= 1 and quantity <= 99),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, book_id)
);

-- 주문
create table if not exists public.orders (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  order_number text not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'shipping', 'delivered', 'confirmed', 'cancelled', 'refunded')),

  -- 배송 정보
  shipping_recipient_name text not null,
  shipping_recipient_phone text not null,
  shipping_postal_code text not null,
  shipping_address_line1 text not null,
  shipping_address_line2 text null,
  shipping_memo text null,

  -- 결제 정보
  payment_method text not null default 'bank_transfer'
    check (payment_method in ('bank_transfer', 'card', 'kakao_pay', 'toss_pay', 'naver_pay')),
  payment_status text not null default 'pending'
    check (payment_status in ('pending', 'paid', 'failed', 'refunded')),

  -- 금액
  subtotal integer not null default 0 check (subtotal >= 0),
  shipping_fee integer not null default 0 check (shipping_fee >= 0),
  discount_amount integer not null default 0 check (discount_amount >= 0),
  total_amount integer not null default 0 check (total_amount >= 0),

  item_count integer not null default 0 check (item_count >= 0),

  -- 배송 추적
  tracking_number text null,
  tracking_carrier text null default 'CJ대한통운',

  -- 구매확정
  confirmed_at timestamptz null,
  auto_confirm_at timestamptz null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 주문 상품
create table if not exists public.order_items (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  book_id bigint not null references public.books(id) on delete restrict,
  product_id bigint null references public.products(id) on delete set null,

  title text not null,
  option_label text null,
  condition_grade text null,
  cover_image_url text null,

  quantity integer not null default 1 check (quantity >= 1),
  unit_price integer not null check (unit_price >= 0),
  total_price integer not null check (total_price >= 0),

  created_at timestamptz not null default now()
);

-- 인덱스
create index if not exists idx_cart_items_user_id on public.cart_items (user_id);
create index if not exists idx_orders_user_id on public.orders (user_id, created_at desc);
create index if not exists idx_orders_status on public.orders (status);
create index if not exists idx_order_items_order_id on public.order_items (order_id);

-- RLS
alter table public.cart_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- cart_items RLS
create policy "cart_items_select_own" on public.cart_items for select to authenticated using (user_id = auth.uid());
create policy "cart_items_insert_own" on public.cart_items for insert to authenticated with check (user_id = auth.uid());
create policy "cart_items_update_own" on public.cart_items for update to authenticated using (user_id = auth.uid());
create policy "cart_items_delete_own" on public.cart_items for delete to authenticated using (user_id = auth.uid());

-- orders RLS
create policy "orders_select_own" on public.orders for select to authenticated using (user_id = auth.uid());
create policy "orders_insert_own" on public.orders for insert to authenticated with check (user_id = auth.uid());
create policy "orders_update_own" on public.orders for update to authenticated using (user_id = auth.uid());

-- order_items RLS
create policy "order_items_select_own" on public.order_items for select to authenticated
  using (order_id in (select id from public.orders where user_id = auth.uid()));

-- admin 전체 접근
create policy "cart_items_admin_all" on public.cart_items for all to authenticated using (public.is_admin_user());
create policy "orders_admin_all" on public.orders for all to authenticated using (public.is_admin_user());
create policy "order_items_admin_all" on public.order_items for all to authenticated using (public.is_admin_user());

-- 주문번호 생성
create or replace function public.generate_order_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  next_number text;
  year_month text;
  seq integer;
begin
  year_month := to_char(now(), 'YYMM');
  select coalesce(max(
    nullif(regexp_replace(order_number, '^ORD-' || year_month || '-', ''), order_number)::integer
  ), 0) + 1 into seq
  from public.orders
  where order_number like 'ORD-' || year_month || '-%';

  next_number := 'ORD-' || year_month || '-' || lpad(seq::text, 4, '0');
  return next_number;
end;
$$;

-- 장바구니 담기 RPC (upsert)
create or replace function public.add_to_cart(
  p_book_id bigint,
  p_product_id bigint default null,
  p_quantity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_cart_id bigint;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  insert into public.cart_items (user_id, book_id, product_id, quantity)
  values (v_user_id, p_book_id, p_product_id, p_quantity)
  on conflict (user_id, book_id) do update
    set quantity = cart_items.quantity + p_quantity,
        updated_at = now()
  returning id into v_cart_id;

  return jsonb_build_object('cart_item_id', v_cart_id);
end;
$$;

-- 장바구니 목록 조회 RPC
create or replace function public.get_cart_items()
returns table (
  id bigint,
  book_id bigint,
  product_id bigint,
  quantity integer,
  title text,
  option_label text,
  subject text,
  brand text,
  condition_grade text,
  price integer,
  original_price integer,
  cover_image_url text,
  stock_count bigint,
  is_sold_out boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    ci.id,
    ci.book_id,
    ci.product_id,
    ci.quantity,
    b.title,
    b.option as option_label,
    b.subject,
    b.brand,
    b.condition_grade,
    b.price,
    b.original_price,
    b.cover_image_url,
    (select count(*) from public.books b2
     where b2.product_id = ci.product_id
       and b2.status = 'on_sale'
       and b2.is_public = true) as stock_count,
    (b.status <> 'on_sale' or not b.is_public) as is_sold_out,
    ci.created_at
  from public.cart_items ci
  join public.books b on b.id = ci.book_id
  where ci.user_id = auth.uid()
  order by ci.created_at desc;
$$;

-- 주문 생성 RPC
create or replace function public.create_order(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'bank_transfer'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_order_id bigint;
  v_order_number text;
  v_subtotal integer := 0;
  v_shipping_fee integer := 3500;
  v_item_count integer;
  v_idx integer;
  v_book record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  v_item_count := array_length(p_book_ids, 1);
  if v_item_count is null or v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;

  if array_length(p_quantities, 1) <> v_item_count then
    raise exception 'book_ids and quantities must have same length';
  end if;

  -- 소계 계산
  for v_idx in 1..v_item_count loop
    select * into v_book from public.books
    where id = p_book_ids[v_idx] and status = 'on_sale' and is_public = true;

    if v_book is null then
      raise exception 'Book % is not available', p_book_ids[v_idx];
    end if;

    v_subtotal := v_subtotal + (coalesce(v_book.price, 0) * p_quantities[v_idx]);
  end loop;

  -- 3만원 이상 무료배송
  if v_subtotal >= 30000 then
    v_shipping_fee := 0;
  end if;

  v_order_number := public.generate_order_number();

  insert into public.orders (
    user_id, order_number, status,
    shipping_recipient_name, shipping_recipient_phone,
    shipping_postal_code, shipping_address_line1, shipping_address_line2, shipping_memo,
    payment_method, payment_status,
    subtotal, shipping_fee, total_amount, item_count,
    auto_confirm_at
  ) values (
    v_user_id, v_order_number, 'paid',
    p_shipping_recipient_name, p_shipping_recipient_phone,
    p_shipping_postal_code, p_shipping_address_line1, p_shipping_address_line2, p_shipping_memo,
    p_payment_method, 'paid',
    v_subtotal, v_shipping_fee, v_subtotal + v_shipping_fee, v_item_count,
    now() + interval '7 days'
  ) returning id into v_order_id;

  -- 주문 상품 생성
  for v_idx in 1..v_item_count loop
    select * into v_book from public.books where id = p_book_ids[v_idx];

    insert into public.order_items (
      order_id, book_id, product_id,
      title, option_label, condition_grade, cover_image_url,
      quantity, unit_price, total_price
    ) values (
      v_order_id, v_book.id, v_book.product_id,
      v_book.title, v_book.option, v_book.condition_grade, v_book.cover_image_url,
      p_quantities[v_idx], coalesce(v_book.price, 0),
      coalesce(v_book.price, 0) * p_quantities[v_idx]
    );
  end loop;

  -- 장바구니에서 삭제
  delete from public.cart_items
  where user_id = v_user_id and book_id = any(p_book_ids);

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'total_amount', v_subtotal + v_shipping_fee,
    'item_count', v_item_count
  );
end;
$$;
