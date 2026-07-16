-- 셀러 정산 명세 투명화 (감사 P1)
--
-- 문제: get_my_settlements가 box_cost_deducted·판매/확정 일자·PU 요청번호를
-- 반환하지 않아 셀러는 "이유 모를 net 금액"만 보고, 타임라인은 항상 미확정,
-- 정산카드 수거 #는 내부 shipment_id 숫자였다. 프론트 매퍼(mapSettlementRow)는
-- 이미 sold_at/confirmed_at 키를 기다리는 상태(P1-5 TODO 주석).
--
-- 변경 (시그니처 동일 — 순수 CREATE OR REPLACE):
--   rows에 box_cost_deducted / sold_at(주문일) / confirmed_at(구매확정일) 추가,
--   pickup_reference를 shipment_id 숫자 → 셀러가 아는 PU 요청번호 우선으로
--   (P0-3 브리지 shipments.pickup_request_id 활용, 미연결 레거시는 기존 값 유지).

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
      o.created_at as sold_at,
      o.confirmed_at as order_confirmed_at,
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.quantity, 1) as quantity,
      b.shipment_id,
      pr.request_number as pickup_request_number
    from public.settlements st
    join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.pickup_requests pr
      on pr.id = sh.pickup_request_id
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
              -- 셀러가 아는 요청번호(PU-xxxx) 우선, 브리지 안 된 레거시는 shipment_id 유지
              'pickup_reference', coalesce(row_data.pickup_request_number, row_data.shipment_id::text),
              'sale_amount', row_data.sale_amount,
              'fee_percent', row_data.fee_percent,
              'fee_amount', row_data.fee_amount,
              'box_cost_deducted', coalesce(row_data.box_cost_deducted, 0),
              'net_amount', row_data.net_amount,
              'status', row_data.status,
              'scheduled_date', row_data.scheduled_date,
              'approved_at', row_data.approved_at,
              'completed_at', row_data.completed_at,
              'sold_at', row_data.sold_at,
              'confirmed_at', row_data.order_confirmed_at,
              'bank_name', row_data.bank_name,
              'account_number', public.mask_account_number(coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number))),
              'account_holder', row_data.account_holder,
              'account_last4', coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number)),
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

grant execute on function public.get_my_settlements(integer, integer) to authenticated;

notify pgrst, 'reload schema';
