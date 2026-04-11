-- TIER 1-3: 정산 자동화
-- 구매확정 시 판매자별 정산 레코드를 생성하고, 운영자 승인/완료 및 회원 정산내역 조회 RPC를 제공한다.

create or replace function public.add_business_days(
  p_start_date date,
  p_business_days integer
)
returns date
language plpgsql
immutable
set search_path = public
as $$
declare
  v_date date := p_start_date;
  v_remaining integer := greatest(0, coalesce(p_business_days, 0));
begin
  while v_remaining > 0 loop
    v_date := v_date + 1;

    if extract(isodow from v_date) between 1 and 5 then
      v_remaining := v_remaining - 1;
    end if;
  end loop;

  return v_date;
end;
$$;

create or replace function public.calculate_settlement_fee_percent(
  p_unit_price integer,
  p_pickup_date date default null
)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case
    when coalesce(p_pickup_date, date '9999-12-31') < date '2026-02-03'
      then case when coalesce(p_unit_price, 0) < 10000 then 35 else 30 end
    else case when coalesce(p_unit_price, 0) < 10000 then 45 else 40 end
  end::numeric(5, 2);
$$;

create table if not exists public.settlements (
  id bigint generated always as identity primary key,
  seller_user_id uuid null references auth.users(id) on delete set null,
  order_id bigint not null references public.orders(id) on delete cascade,
  order_item_id bigint null references public.order_items(id) on delete set null,
  book_id bigint not null references public.books(id) on delete restrict,

  sale_amount integer not null default 0 check (sale_amount >= 0),
  fee_percent numeric(5, 2) not null check (fee_percent >= 0 and fee_percent <= 100),
  fee_amount integer not null default 0 check (fee_amount >= 0),
  net_amount integer not null default 0 check (net_amount >= 0),

  status text not null default 'pending'
    check (status in ('pending', 'approved', 'completed')),
  scheduled_date date not null,
  approved_at timestamptz null,
  completed_at timestamptz null,

  bank_name text null,
  account_number text null,
  account_holder text null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (order_id, book_id)
);

create index if not exists idx_settlements_seller_status_scheduled
  on public.settlements (seller_user_id, status, scheduled_date desc);

create index if not exists idx_settlements_status_scheduled
  on public.settlements (status, scheduled_date desc);

create index if not exists idx_settlements_order_id
  on public.settlements (order_id);

create index if not exists idx_settlements_book_id
  on public.settlements (book_id);

alter table public.settlements enable row level security;

drop policy if exists settlements_select_own on public.settlements;
drop policy if exists settlements_admin_all on public.settlements;

create policy settlements_select_own
  on public.settlements
  for select
  to authenticated
  using (seller_user_id = auth.uid());

create policy settlements_admin_all
  on public.settlements
  for all
  to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

create or replace function public.touch_settlements_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists settlements_set_updated_at on public.settlements;
create trigger settlements_set_updated_at
before update on public.settlements
for each row
execute function public.touch_settlements_updated_at();

create or replace function public.create_settlements_for_order(p_order_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_item record;
  v_unit_price integer;
  v_sale_amount integer;
  v_fee_percent numeric(5, 2);
  v_fee_amount integer;
  v_inserted_count integer := 0;
begin
  select *
  into v_order
  from public.orders
  where id = p_order_id
    and status = 'confirmed'
    and confirmed_at is not null;

  if not found then
    return 0;
  end if;

  for v_item in
    select
      oi.id as order_item_id,
      oi.book_id,
      oi.quantity,
      oi.unit_price,
      oi.total_price,
      b.shipment_id,
      s.user_id as seller_user_id,
      s.pickup_date,
      msa.bank_name,
      msa.account_number,
      msa.account_holder
    from public.order_items oi
    join public.books b
      on b.id = oi.book_id
    left join public.shipments s
      on s.id = b.shipment_id
    left join lateral (
      select
        account.bank_name,
        account.account_number,
        account.account_holder
      from public.member_settlement_accounts account
      where account.user_id = s.user_id
      order by account.is_default desc, account.created_at desc, account.id desc
      limit 1
    ) msa on true
    where oi.order_id = p_order_id
  loop
    v_sale_amount := greatest(0, coalesce(v_item.total_price, v_item.unit_price * greatest(1, coalesce(v_item.quantity, 1)), 0));
    v_unit_price := greatest(
      0,
      coalesce(
        v_item.unit_price,
        case
          when coalesce(v_item.quantity, 0) > 0 then floor(v_sale_amount::numeric / v_item.quantity)::integer
          else v_sale_amount
        end,
        0
      )
    );
    v_fee_percent := public.calculate_settlement_fee_percent(v_unit_price, v_item.pickup_date);
    v_fee_amount := floor(v_sale_amount * (v_fee_percent / 100))::integer;

    insert into public.settlements (
      seller_user_id,
      order_id,
      order_item_id,
      book_id,
      sale_amount,
      fee_percent,
      fee_amount,
      net_amount,
      status,
      scheduled_date,
      bank_name,
      account_number,
      account_holder
    )
    values (
      v_item.seller_user_id,
      p_order_id,
      v_item.order_item_id,
      v_item.book_id,
      v_sale_amount,
      v_fee_percent,
      v_fee_amount,
      greatest(0, v_sale_amount - v_fee_amount),
      'pending',
      public.add_business_days((v_order.confirmed_at at time zone 'Asia/Seoul')::date, 3),
      v_item.bank_name,
      v_item.account_number,
      v_item.account_holder
    )
    on conflict (order_id, book_id) do nothing;

    if found then
      v_inserted_count := v_inserted_count + 1;
    end if;
  end loop;

  return v_inserted_count;
end;
$$;

create or replace function public.create_order_settlements_after_confirm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'confirmed'
     and new.confirmed_at is not null
     and (
       tg_op = 'INSERT'
       or old.confirmed_at is null
       or old.status is distinct from 'confirmed'
     ) then
    perform public.create_settlements_for_order(new.id);
  end if;

  return new;
end;
$$;

drop trigger if exists orders_create_settlements_after_confirm on public.orders;
create trigger orders_create_settlements_after_confirm
after insert or update of status, confirmed_at on public.orders
for each row
execute function public.create_order_settlements_after_confirm();

-- 기존 구매확정 주문 백필. 이미 생성된 정산은 unique(order_id, book_id)로 건너뛴다.
select public.create_settlements_for_order(o.id)
from public.orders o
where o.status = 'confirmed'
  and o.confirmed_at is not null;

create or replace function public.list_admin_settlements(
  p_statuses text[] default null,
  p_search text default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 100,
  p_offset integer default 0
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

  with filtered as (
    select
      st.*,
      o.order_number,
      o.confirmed_at,
      oi.quantity,
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.condition_grade, b.condition_grade) as condition_grade,
      b.shipment_id,
      sh.seller_name as shipment_seller_name,
      sh.seller_phone as shipment_seller_phone,
      mp.email as seller_email,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as seller_phone
    from public.settlements st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.member_profiles mp
      on mp.user_id = st.seller_user_id
    where
      (coalesce(cardinality(p_statuses), 0) = 0 or st.status = any(p_statuses))
      and (p_from_date is null or st.scheduled_date >= p_from_date)
      and (p_to_date is null or st.scheduled_date <= p_to_date)
      and (
        nullif(btrim(coalesce(p_search, '')), '') is null
        or o.order_number ilike '%' || btrim(p_search) || '%'
        or coalesce(oi.title, b.title) ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.name, sh.seller_name, '') ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.email, '') ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.phone, sh.seller_phone, '') ilike '%' || btrim(p_search) || '%'
      )
  ),
  page_rows as (
    select *
    from filtered
    order by
      case status when 'pending' then 1 when 'approved' then 2 else 3 end,
      scheduled_date asc,
      id desc
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 100), 500))
  )
  select jsonb_build_object(
    'rows',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', row_data.id,
            'seller_user_id', row_data.seller_user_id,
            'seller_name', coalesce(row_data.seller_name, '판매자 미연결'),
            'seller_email', row_data.seller_email,
            'seller_phone', row_data.seller_phone,
            'order_id', row_data.order_id,
            'order_number', row_data.order_number,
            'order_item_id', row_data.order_item_id,
            'book_id', row_data.book_id,
            'book_title', row_data.book_title,
            'book_option', row_data.book_option,
            'condition_grade', row_data.condition_grade,
            'shipment_id', row_data.shipment_id,
            'sale_amount', row_data.sale_amount,
            'fee_percent', row_data.fee_percent,
            'fee_amount', row_data.fee_amount,
            'net_amount', row_data.net_amount,
            'status', row_data.status,
            'scheduled_date', row_data.scheduled_date,
            'approved_at', row_data.approved_at,
            'completed_at', row_data.completed_at,
            'bank_name', row_data.bank_name,
            'account_number', row_data.account_number,
            'account_holder', row_data.account_holder,
            'account_last4', right(regexp_replace(coalesce(row_data.account_number, ''), '[^0-9]', '', 'g'), 4),
            'confirmed_at', row_data.confirmed_at,
            'created_at', row_data.created_at,
            'updated_at', row_data.updated_at
          )
          order by
            case row_data.status when 'pending' then 1 when 'approved' then 2 else 3 end,
            row_data.scheduled_date asc,
            row_data.id desc
        )
        from page_rows row_data
      ),
      '[]'::jsonb
    ),
    'total_count', (select count(*) from filtered),
    'summary',
    jsonb_build_object(
      'pending_count', (select count(*) from filtered where status = 'pending'),
      'approved_count', (select count(*) from filtered where status = 'approved'),
      'completed_count', (select count(*) from filtered where status = 'completed'),
      'pending_amount', coalesce((select sum(net_amount) from filtered where status = 'pending'), 0),
      'approved_amount', coalesce((select sum(net_amount) from filtered where status = 'approved'), 0),
      'completed_amount', coalesce((select sum(net_amount) from filtered where status = 'completed'), 0),
      'due_pending_count', (select count(*) from filtered where status = 'pending' and scheduled_date <= current_date),
      'due_pending_amount', coalesce((select sum(net_amount) from filtered where status = 'pending' and scheduled_date <= current_date), 0)
    )
  )
  into v_result;

  return v_result;
end;
$$;

create or replace function public.admin_approve_settlements(p_settlement_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  with account_snapshot as (
    select
      st.id,
      account.bank_name,
      account.account_number,
      account.account_holder
    from public.settlements st
    left join lateral (
      select
        msa.bank_name,
        msa.account_number,
        msa.account_holder
      from public.member_settlement_accounts msa
      where msa.user_id = st.seller_user_id
      order by msa.is_default desc, msa.created_at desc, msa.id desc
      limit 1
    ) account on true
    where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
  )
  update public.settlements st
  set
    status = 'approved',
    approved_at = coalesce(st.approved_at, now()),
    bank_name = coalesce(nullif(btrim(st.bank_name), ''), account_snapshot.bank_name),
    account_number = coalesce(nullif(btrim(st.account_number), ''), account_snapshot.account_number),
    account_holder = coalesce(nullif(btrim(st.account_holder), ''), account_snapshot.account_holder)
  from account_snapshot
  where st.id = account_snapshot.id
    and st.status = 'pending';

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'updated_count', v_updated_count);
end;
$$;

create or replace function public.admin_complete_settlements(p_settlement_ids bigint[])
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

  with account_snapshot as (
    select
      st.id,
      coalesce(nullif(btrim(st.bank_name), ''), account.bank_name) as next_bank_name,
      coalesce(nullif(btrim(st.account_number), ''), account.account_number) as next_account_number,
      coalesce(nullif(btrim(st.account_holder), ''), account.account_holder) as next_account_holder
    from public.settlements st
    left join lateral (
      select
        msa.bank_name,
        msa.account_number,
        msa.account_holder
      from public.member_settlement_accounts msa
      where msa.user_id = st.seller_user_id
      order by msa.is_default desc, msa.created_at desc, msa.id desc
      limit 1
    ) account on true
    where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
      and st.status = 'approved'
  ),
  updated as (
    update public.settlements st
    set
      status = 'completed',
      completed_at = now(),
      bank_name = account_snapshot.next_bank_name,
      account_number = account_snapshot.next_account_number,
      account_holder = account_snapshot.next_account_holder
    from account_snapshot
    where st.id = account_snapshot.id
      and nullif(btrim(coalesce(account_snapshot.next_bank_name, '')), '') is not null
      and nullif(btrim(coalesce(account_snapshot.next_account_number, '')), '') is not null
      and nullif(btrim(coalesce(account_snapshot.next_account_holder, '')), '') is not null
    returning st.*
  ),
  settled_books as (
    update public.books b
    set status = 'settled'
    where b.id in (select book_id from updated)
      and b.status <> 'settled'
    returning b.id
  ),
  updated_rows as (
    select
      st.*,
      o.order_number,
      coalesce(oi.title, b.title) as book_title,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as seller_phone,
      mp.email as seller_email
    from updated st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.member_profiles mp
      on mp.user_id = st.seller_user_id
  )
  select jsonb_build_object(
    'success', true,
    'updated_count', (select count(*) from updated_rows),
    'skipped_missing_account_count',
      (
        select count(*)
        from account_snapshot p
        where nullif(btrim(coalesce(p.next_bank_name, '')), '') is null
           or nullif(btrim(coalesce(p.next_account_number, '')), '') is null
           or nullif(btrim(coalesce(p.next_account_holder, '')), '') is null
      ),
    'settled_book_count', (select count(*) from settled_books),
    'settlements',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', row_data.id,
              'seller_user_id', row_data.seller_user_id,
              'seller_name', row_data.seller_name,
              'seller_phone', row_data.seller_phone,
              'seller_email', row_data.seller_email,
              'order_id', row_data.order_id,
              'order_number', row_data.order_number,
              'book_id', row_data.book_id,
              'book_title', row_data.book_title,
              'net_amount', row_data.net_amount,
              'bank_name', row_data.bank_name,
              'account_number', row_data.account_number,
              'account_holder', row_data.account_holder,
              'account_last4', right(regexp_replace(coalesce(row_data.account_number, ''), '[^0-9]', '', 'g'), 4),
              'completed_at', row_data.completed_at
            )
            order by row_data.id
          )
          from updated_rows row_data
        ),
        '[]'::jsonb
      )
  )
  into v_result;

  return v_result;
end;
$$;

create or replace function public.get_my_settlements(
  p_limit integer default 50,
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

  with rows as (
    select
      st.*,
      o.order_number,
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.quantity, 1) as quantity,
      b.shipment_id
    from public.settlements st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    where st.seller_user_id = v_user_id
    order by
      case st.status when 'completed' then 1 when 'approved' then 2 else 3 end,
      coalesce(st.completed_at, st.scheduled_date::timestamptz, st.created_at) desc,
      st.id desc
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  ),
  all_my_settlements as (
    select *
    from public.settlements
    where seller_user_id = v_user_id
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', row_data.id,
              'order_id', row_data.order_id,
              'order_number', row_data.order_number,
              'book_id', row_data.book_id,
              'book_title', row_data.book_title,
              'book_option', row_data.book_option,
              'book_count', greatest(1, coalesce(row_data.quantity, 1)),
              'pickup_reference', row_data.shipment_id,
              'sale_amount', row_data.sale_amount,
              'fee_percent', row_data.fee_percent,
              'fee_amount', row_data.fee_amount,
              'net_amount', row_data.net_amount,
              'status', row_data.status,
              'scheduled_date', row_data.scheduled_date,
              'approved_at', row_data.approved_at,
              'completed_at', row_data.completed_at,
              'bank_name', row_data.bank_name,
              'account_number', row_data.account_number,
              'account_holder', row_data.account_holder,
              'account_last4', right(regexp_replace(coalesce(row_data.account_number, ''), '[^0-9]', '', 'g'), 4),
              'created_at', row_data.created_at
            )
            order by
              case row_data.status when 'completed' then 1 when 'approved' then 2 else 3 end,
              coalesce(row_data.completed_at, row_data.scheduled_date::timestamptz, row_data.created_at) desc,
              row_data.id desc
          )
          from rows row_data
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

grant execute on function public.add_business_days(date, integer) to anon, authenticated;
grant execute on function public.calculate_settlement_fee_percent(integer, date) to anon, authenticated;
grant execute on function public.create_settlements_for_order(bigint) to authenticated;
grant execute on function public.list_admin_settlements(text[], text, date, date, integer, integer) to authenticated;
grant execute on function public.admin_approve_settlements(bigint[]) to authenticated;
grant execute on function public.admin_complete_settlements(bigint[]) to authenticated;
grant execute on function public.get_my_settlements(integer, integer) to authenticated;
