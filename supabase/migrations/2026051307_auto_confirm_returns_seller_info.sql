-- 묶음 10-1: auto_confirm_delivered_orders RPC가 confirmed 주문의 셀러 정보를 반환하도록 확장.
-- cron 핸들러가 그 결과를 받아 셀러별 notifySold 알림 발송.

create or replace function public.auto_confirm_delivered_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
      -- 정산 예정일: 구매확정 + 3영업일 (settlements가 따라가는 동일 규칙)
      'settlement_date', to_char(
        public.add_business_days((o.confirmed_at at time zone 'Asia/Seoul')::date, 3),
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
$$;
