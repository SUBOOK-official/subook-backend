-- 정산 정책 변경: 구매확정 후 D+3 영업일 → '매월 1일 정산' (사업 기조 변경, 2026-07-02).
--
-- 변경 범위 (비파괴, CREATE OR REPLACE):
--   1) next_settlement_date(timestamptz) 헬퍼 신설 — 익월 1일 반환.
--   2) create_settlements_for_order: settlements.scheduled_date 를 add_business_days(+3) → next_settlement_date 로.
--   3) auto_confirm_delivered_orders: 알림톡용 settlement_date 도 동일 규칙으로.
--   * 현재 settlements 레코드 0건 → 기존 데이터 재조정 불필요. add_business_days 헬퍼는 다른 용도 위해 유지.
--   * 두 함수는 pg_get_functiondef 로 받은 현재 정의에서 scheduled_date 계산 1줄만 치환(그 외 로직 동일).

-- 정산 예정일 헬퍼: '매월 1일 정산' 정책 — 구매확정된 판매분은 '익월 1일'에 정산.
-- (구매확정 KST 기준 그 달의 판매분을 모아 다음 달 1일에 지급. 예: 1/15 확정 → 2/1 정산)
create or replace function public.next_settlement_date(p_confirmed_at timestamptz)
returns date
language sql
stable
as $$
  select (date_trunc('month', (coalesce(p_confirmed_at, now()) at time zone 'Asia/Seoul')::date) + interval '1 month')::date;
$$;

grant execute on function public.next_settlement_date(timestamptz) to anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_settlements_for_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      public.next_settlement_date(v_order.confirmed_at),
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
$function$;

CREATE OR REPLACE FUNCTION public.auto_confirm_delivered_orders()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_confirmed_count integer;
  v_sellers jsonb;
begin
  -- 1) 자동 구매확정 전이
  with updated as (
    update public.orders
    set
      status = 'confirmed',
      confirmed_at = now(),
      updated_at = now()
    where
      status = 'delivered'
      and confirmed_at is null
      and auto_confirm_at is not null
      and auto_confirm_at <= now()
    returning id
  )
  select count(*) into v_confirmed_count from updated;

  -- 2) 방금 confirmed된 주문에 묶인 책별 셀러 정보 + 정산 예정일 수집
  select coalesce(jsonb_agg(row_data order by row_data->>'order_id'), '[]'::jsonb)
  into v_sellers
  from (
    select jsonb_build_object(
      'order_id', o.id,
      'order_number', o.order_number,
      'book_title', coalesce(oi.title, b.title),
      'seller_user_id', sh.user_id,
      'seller_name', coalesce(nullif(btrim(mp.name), ''), sh.seller_name),
      'seller_phone', coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone),
      -- 정산 예정일: 익월 1일 (settlements.scheduled_date와 동일 규칙 — 매월 1일 정산)
      'settlement_date', to_char(
        public.next_settlement_date(o.confirmed_at),
        'YYYY-MM-DD'
      )
    ) as row_data
    from public.orders o
    join public.order_items oi
      on oi.order_id = o.id
    join public.books b
      on b.id = oi.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.member_profiles mp
      on mp.user_id = sh.user_id
    where
      o.status = 'confirmed'
      and o.confirmed_at is not null
      and o.confirmed_at >= now() - interval '5 minutes'  -- 방금 처리된 것만
      and coalesce(nullif(btrim(coalesce(mp.phone, sh.seller_phone, '')), ''), '') <> ''
  ) sub;

  return jsonb_build_object(
    'success', true,
    'confirmed_count', v_confirmed_count,
    'sellers_to_notify', v_sellers,
    'executed_at', now()
  );
end;
$function$;

notify pgrst, 'reload schema';
