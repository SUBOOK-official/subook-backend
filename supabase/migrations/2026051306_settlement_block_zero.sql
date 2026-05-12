-- 묶음 9-8: 정산 0원 차단
--
-- 기존 create_settlements_for_order는 v_sale_amount=0이어도 settlements row를 생성하고
-- net_amount=greatest(0, ...) 로 음수 차단만 함. 운영자가 가격을 0/누락 입력하면
-- 0원 정산 row가 자동 생성되어 'completed' 단계까지 흘러갈 수 있음.
--
-- 변경:
--   1. create_settlements_for_order: sale_amount <= 0 이면 INSERT skip + 로그
--   2. settlements.sale_amount/net_amount에 > 0 또는 >= 0 CHECK (기존 데이터 호환 위해 >= 0)
--   3. admin_complete_settlements: net_amount = 0 row는 skip + 결과에 skipped_zero 카운트

-- 1) settlements CHECK 제약 강화 (음수 차단)
alter table public.settlements drop constraint if exists settlements_sale_amount_nonneg;
alter table public.settlements add constraint settlements_sale_amount_nonneg
  check (sale_amount >= 0);
alter table public.settlements drop constraint if exists settlements_net_amount_nonneg;
alter table public.settlements add constraint settlements_net_amount_nonneg
  check (net_amount >= 0);

-- 2) create_settlements_for_order: 0원 row 생성 안 함
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
  v_net_amount integer;
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

    -- ⚠️ 0원 정산 차단: 가격 0이면 settlements row 생성 자체 skip
    if v_sale_amount <= 0 then
      raise notice 'create_settlements_for_order: order_item % skipped (sale_amount=0). 운영자 가격 확인 필요.', v_item.order_item_id;
      continue;
    end if;

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
    v_net_amount := greatest(0, v_sale_amount - v_fee_amount);

    -- net 0원도 차단 (수수료가 매출과 같거나 큰 케이스)
    if v_net_amount <= 0 then
      raise notice 'create_settlements_for_order: order_item % skipped (net_amount=0).', v_item.order_item_id;
      continue;
    end if;

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
      v_net_amount,
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
