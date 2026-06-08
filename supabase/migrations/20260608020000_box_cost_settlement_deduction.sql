-- 박스당 상품화 비용(5,000원/박스) 정산 자동 차감.
--
-- 정책: 수거는 무료, 박스 1개당 상품화 비용 5,000원을 교재 판매 후 정산에서 차감.
-- 출처: admin이 검수/입고 시 shipments.box_count에 '실제 받은 박스 수'를 기록(셀러 신고값 아님).
-- 분배: 그 수거(shipment)의 첫 판매 정산건 net에서 전액 차감, net이 모자라면 다음 정산으로 이월.
-- 중복차감 방지: shipments.box_cost_charged에 누적 차감액 추적 + 신규 settlement insert 시에만 차감.
--                shipment 행을 FOR UPDATE로 잠가 동일 수거의 여러 책/동시 정산을 직렬화.
--
-- 비파괴: 컬럼은 default 0으로 추가 → admin이 box_count를 넣기 전까지 차감 0(기존 동작 동일).
--         CREATE OR REPLACE FUNCTION(시그니처 동일, 기존 grant 유지).

alter table public.shipments
  add column if not exists box_count integer not null default 0,
  add column if not exists box_cost_charged integer not null default 0;

alter table public.settlements
  add column if not exists box_cost_deducted integer not null default 0;

create or replace function public.create_settlements_for_order(p_order_id bigint)
returns jsonb
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
  v_net_pre integer;
  v_box_cost_per_box constant integer := 5000;
  v_box_count integer;
  v_box_charged integer;
  v_box_remaining integer;
  v_box_deduct integer;
  v_net_amount integer;
  v_inserted_count integer := 0;
begin
  select * into v_order
    from public.orders
   where id = p_order_id
     and status = 'confirmed'
     and confirmed_at is not null;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'order_not_confirmed');
  end if;

  for v_item in
    select
      oi.id        as order_item_id,
      oi.book_id,
      oi.quantity,
      oi.unit_price,
      oi.total_price,
      b.shipment_id,
      s.user_id    as seller_user_id,
      s.pickup_date,
      msa.bank_name,
      msa.account_number_ciphertext,
      coalesce(msa.account_number_last4, public.get_account_last4(msa.account_number)) as account_number_last4,
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
        account.account_number_ciphertext,
        account.account_number_last4,
        account.account_holder
      from public.member_settlement_accounts account
      where account.user_id = s.user_id
      order by account.is_default desc, account.created_at desc, account.id desc
      limit 1
    ) msa on true
    where oi.order_id = p_order_id
  loop
    -- 자체매입(셀러 미연결) 건은 정산 대상 아님
    if v_item.seller_user_id is null then
      continue;
    end if;

    v_sale_amount := greatest(
      0,
      coalesce(v_item.total_price,
               v_item.unit_price * greatest(1, coalesce(v_item.quantity, 1)),
               0)
    );
    if v_sale_amount <= 0 then
      continue;
    end if;

    v_unit_price := greatest(
      0,
      coalesce(
        v_item.unit_price,
        case
          when coalesce(v_item.quantity, 0) > 0
            then floor(v_sale_amount::numeric / v_item.quantity)::integer
          else v_sale_amount
        end,
        0
      )
    );

    v_fee_percent := public.calculate_settlement_fee_percent(v_unit_price, v_item.pickup_date);
    v_fee_amount := round(v_sale_amount * (v_fee_percent / 100))::integer;

    v_net_pre := v_sale_amount - v_fee_amount;
    if v_net_pre <= 0 then
      raise notice 'create_settlements_for_order: net_amount<=0 skip order=% book=%',
        p_order_id, v_item.book_id;
      continue;
    end if;

    -- 박스당 상품화 비용 차감 (shipment 단위, 첫 정산부터 차감 + 이월).
    -- shipment 행을 잠가 동일 수거의 여러 책/동시 정산이 같은 box_cost_charged를 두 번 읽는 것을 방지.
    v_box_deduct := 0;
    v_net_amount := v_net_pre;
    if v_item.shipment_id is not null then
      select coalesce(box_count, 0), coalesce(box_cost_charged, 0)
        into v_box_count, v_box_charged
        from public.shipments
       where id = v_item.shipment_id
       for update;
      v_box_remaining := greatest(0, (v_box_count * v_box_cost_per_box) - v_box_charged);
      v_box_deduct := least(v_box_remaining, v_net_pre);
      v_net_amount := v_net_pre - v_box_deduct;
    end if;

    insert into public.settlements (
      seller_user_id, order_id, order_item_id, book_id,
      sale_amount, fee_percent, fee_amount, net_amount, box_cost_deducted,
      status, scheduled_date,
      bank_name, account_number, account_number_ciphertext, account_number_last4, account_holder
    )
    values (
      v_item.seller_user_id, p_order_id, v_item.order_item_id, v_item.book_id,
      v_sale_amount, v_fee_percent, v_fee_amount, v_net_amount, v_box_deduct,
      'pending',
      public.add_business_days((v_order.confirmed_at at time zone 'Asia/Seoul')::date, 3),
      v_item.bank_name,
      public.mask_account_number(v_item.account_number_last4),
      v_item.account_number_ciphertext,
      v_item.account_number_last4,
      v_item.account_holder
    )
    on conflict (order_id, book_id) do nothing;

    if found then
      v_inserted_count := v_inserted_count + 1;
      -- 차감은 settlement가 실제로 새로 생성된 경우에만 누적(재실행 중복차감 방지).
      if v_box_deduct > 0 then
        update public.shipments
          set box_cost_charged = coalesce(box_cost_charged, 0) + v_box_deduct
          where id = v_item.shipment_id;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'inserted_count', v_inserted_count
  );
end;
$$;

notify pgrst, 'reload schema';
