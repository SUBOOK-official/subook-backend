-- 수동정산 ↔ 자동정산 이중 지급 방지 (2026-08-09 운영 사고 후속)
--
-- 배경: 운영자가 회원 주문으로 팔린 책까지 엑셀(수동정산)로 지급 처리 →
--   같은 책의 자동 정산(settlements)이 pending으로 남아 9/1 이중 지급될 뻔함.
--   현재 데이터 14건은 Management API로 일괄 cancelled 처리 완료
--   (백업: backups/settlements-manual-dedupe-2026-08-09).
--
-- 정책(사용자 결정 2026-08-09): 수동정산이 이뤄진 책은 자동 정산에 뜨지 않는다(수동 우선).
--   1) admin_commit_manual_settlement: 커밋 시 해당 책의 pending/approved 자동 정산을
--      자동 취소하고, 그 정산이 차감했던 박스비는 shipment로 원복.
--      이미 completed/recovery_required(실지급됨)인 책은 수동정산 레코드 생성 자체를
--      skip하고 개수 반환(반대 방향 이중 지급 방어).
--   2) create_settlements_for_order: 활성 수동정산 레코드가 있는 책은 정산 생성 제외.
--      (엑셀 지급 후 D+7 자동 구매확정이 돌 때 중복이 되살아나는 구멍 차단 —
--       2026-08-09 기준 delivered 89권 + preparing 1권이 이 케이스였음)
--   3) get_my_settlements: cancelled/recovery_required를 셀러 목록에서 제외.
--      (프론트 memberPortal.js가 completed 외 전부 '정산 예정'으로 렌더하므로
--       취소 건이 새면 셀러 마이페이지에 raw 상태로 노출됨)
--
-- ⚠ 재정의 시 유지 필수:
--   - (1)의 자동 취소 + 박스비 원복 + completed skip
--   - (2)의 refunded_at 필터·박스비 차감·매월 1일(next_settlement_date)·수동정산 제외 필터
--   - (3)의 legacy manual UNION arm(20260805114844) + 상태 필터

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) admin_commit_manual_settlement — 자동 정산 자동 취소 + 실지급 책 skip
--    (20260629000000 최신 정의 기반)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_commit_manual_settlement(
  p_items jsonb,
  p_update_price boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item              jsonb;
  v_book_id           bigint;
  v_sale              integer;
  v_batch             text;
  v_book              record;
  v_fee_percent       numeric(5, 2);
  v_fee               integer;
  v_net               integer;
  v_existing_status   text;
  v_settled_count     integer := 0;
  v_already_settled   integer := 0;
  v_record_created    integer := 0;
  v_record_updated    integer := 0;
  v_price_updated     integer := 0;
  v_skipped_paid      integer := 0;
  v_skipped_discarded integer := 0;
  v_not_found         integer := 0;
  v_skipped_auto_settled integer := 0;
  v_auto_cancelled    integer := 0;
  v_processed_book_ids bigint[] := array[]::bigint[];
  v_uid               uuid := auth.uid();
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_book_id := nullif(v_item->>'book_id', '')::bigint;
    v_sale := greatest(0, coalesce(nullif(v_item->>'sale_amount', '')::integer, 0));
    v_batch := nullif(v_item->>'batch_label', '');

    if v_book_id is null then
      continue;
    end if;

    select b.id, b.status, b.price, b.shipment_id,
           s.seller_name, s.seller_phone, s.pickup_date
      into v_book
      from public.books b
      left join public.shipments s on s.id = b.shipment_id
      where b.id = v_book_id;

    if not found then
      v_not_found := v_not_found + 1;
      continue;
    end if;

    if v_book.status = 'discarded' then
      v_skipped_discarded := v_skipped_discarded + 1;
      continue;
    end if;

    -- 자동 정산으로 이미 실지급된 책은 수동정산 기록을 만들지 않는다 (이중 지급 방어).
    if exists (
      select 1
      from public.settlements st
      where st.book_id = v_book_id
        and st.status in ('completed', 'recovery_required')
    ) then
      v_skipped_auto_settled := v_skipped_auto_settled + 1;
      continue;
    end if;

    v_processed_book_ids := v_processed_book_ids || v_book_id;

    -- (선택) 판매가 갱신: 엑셀 실판매가로 books.price 정정
    if p_update_price and v_sale > 0 and v_book.price is distinct from v_sale then
      update public.books set price = v_sale where id = v_book_id;
      v_price_updated := v_price_updated + 1;
    end if;

    -- 예상 정산액(참고용): 플랫폼 수수료 공식. 식스샵 실제 정산액과 다를 수 있음.
    v_fee_percent := public.calculate_settlement_fee_percent(v_sale, coalesce(v_book.pickup_date, current_date));
    v_fee := floor(v_sale * (coalesce(v_fee_percent, 0) / 100))::integer;
    v_net := greatest(0, v_sale - v_fee);

    -- 책 상태 플립 (재고 축)
    if v_book.status = 'settled' then
      v_already_settled := v_already_settled + 1;
    elsif v_book.status in ('on_sale', 'reserved') then
      update public.books set status = 'settled' where id = v_book_id;
      v_settled_count := v_settled_count + 1;
    end if;

    -- 정산 레코드 upsert (입금완료 레코드는 금액 보존)
    select status into v_existing_status from public.manual_settlements where book_id = v_book_id;

    if not found then
      insert into public.manual_settlements (
        book_id, shipment_id, seller_name, seller_phone, source, batch_label,
        sale_amount, fee_percent, fee_amount, net_amount, status, created_by
      ) values (
        v_book_id, v_book.shipment_id, v_book.seller_name, v_book.seller_phone, 'sixshop', v_batch,
        v_sale, v_fee_percent, v_fee, v_net, 'unpaid', v_uid
      );
      v_record_created := v_record_created + 1;
    elsif v_existing_status = 'paid' then
      v_skipped_paid := v_skipped_paid + 1;
    else
      update public.manual_settlements set
        shipment_id  = v_book.shipment_id,
        seller_name  = v_book.seller_name,
        seller_phone = v_book.seller_phone,
        batch_label  = coalesce(v_batch, batch_label),
        sale_amount  = v_sale,
        fee_percent  = v_fee_percent,
        fee_amount   = v_fee,
        net_amount   = v_net,
        status       = 'unpaid'
      where book_id = v_book_id;
      v_record_updated := v_record_updated + 1;
    end if;
  end loop;

  -- 수동정산 우선 정책(2026-08-09): 방금 수동정산으로 잡은 책의 대기/승인 자동 정산은
  -- 자동 취소하고, 그 정산이 차감했던 박스비는 shipment로 원복한다(박스비 미회수 상태로 복귀).
  if coalesce(array_length(v_processed_book_ids, 1), 0) > 0 then
    with cancelled as (
      update public.settlements st
      set status = 'cancelled',
          cancelled_at = now(),
          refund_reason = coalesce(st.refund_reason, '수동정산(엑셀) 처리로 자동 취소'),
          updated_at = now()
      where st.book_id = any(v_processed_book_ids)
        and st.status in ('pending', 'approved')
      returning st.book_id, coalesce(st.box_cost_deducted, 0) as box_deduct
    ),
    box_restore as (
      update public.shipments sh
      set box_cost_charged = greatest(0, coalesce(sh.box_cost_charged, 0) - agg.total_deduct)
      from (
        select b.shipment_id, sum(c.box_deduct) as total_deduct
        from cancelled c
        join public.books b on b.id = c.book_id
        where b.shipment_id is not null
          and c.box_deduct > 0
        group by b.shipment_id
      ) agg
      where sh.id = agg.shipment_id
      returning sh.id
    )
    select count(*) into v_auto_cancelled from cancelled;
  end if;

  return jsonb_build_object(
    'settled_count', v_settled_count,
    'already_settled_count', v_already_settled,
    'record_created', v_record_created,
    'record_updated', v_record_updated,
    'price_updated_count', v_price_updated,
    'skipped_paid_count', v_skipped_paid,
    'skipped_discarded_count', v_skipped_discarded,
    'not_found_count', v_not_found,
    'auto_settlement_cancelled', v_auto_cancelled,
    'skipped_auto_settled_count', v_skipped_auto_settled
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) create_settlements_for_order — 활성 수동정산 책 제외
--    (20260731174237 최신 정의 기반, item 루프 where에 not exists 1개 추가.
--     ⚠ 재정의 시 refunded_at 필터 + 수동정산 제외 + 박스비 차감·매월 1일 유지 필수)
-- ─────────────────────────────────────────────────────────────────────────────
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
      -- ⚠ 부분환불된 품목은 정산 생성 제외 (2026-08-01 품목별 부분환불 도입)
      and oi.refunded_at is null
      -- ⚠ 수동정산(엑셀)으로 지급 추적 중인 책은 자동 정산 생성 제외
      --   (2026-08-09 수동 우선 정책 — 엑셀 지급 후 자동 구매확정 시 중복 방지)
      and not exists (
        select 1
        from public.manual_settlements ms
        where ms.book_id = oi.book_id
          and ms.status <> 'cancelled'
      )
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) get_my_settlements — cancelled/recovery_required 셀러 목록 제외
--    (20260805114844 최신 정의 기반 — legacy manual UNION arm 유지 필수.
--     platform arm: pending/approved/completed만, manual arm: cancelled 제외)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_my_settlements(
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  with platform_rows as (
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
      -- 취소(환불·수동정산 대체)/회수 대상은 셀러 목록에서 제외
      -- (프론트는 completed 외 전부 '정산 예정'으로 렌더하므로 새면 안 됨)
      and st.status in ('pending', 'approved', 'completed')
  ),
  -- 구 수북(식스샵) 판매분 수동정산 — shipment 소유자 기준으로 본인 것만
  manual_rows as (
    select
      ms.id,
      ms.book_id,
      b.title as book_title,
      b.option as book_option,
      ms.shipment_id,
      ms.sale_amount,
      ms.fee_percent,
      ms.fee_amount,
      ms.net_amount,
      case when ms.status = 'paid' then 'completed' else 'pending' end as status,
      ms.paid_at,
      ms.sold_at,
      ms.created_at
    from public.manual_settlements ms
    join public.shipments s
      on s.id = ms.shipment_id
    left join public.books b
      on b.id = ms.book_id
    where s.user_id = v_user_id
      and ms.status <> 'cancelled'
  ),
  combined as (
    select
      jsonb_build_object(
        'id', row_data.id,
        'source', 'platform',
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
      ) as row_json,
      case row_data.status when 'completed' then 1 when 'approved' then 2 else 3 end as status_rank,
      coalesce(row_data.completed_at, row_data.scheduled_date::timestamptz, row_data.created_at) as sort_ts,
      row_data.id::text as sort_id
    from platform_rows row_data

    union all

    select
      jsonb_build_object(
        'id', 'manual-' || mr.id::text,
        'source', 'manual',
        'order_id', null,
        'order_number', null,
        'book_id', mr.book_id,
        'book_title', mr.book_title,
        'book_option', mr.book_option,
        'book_count', 1,
        'pickup_reference', mr.shipment_id::text,
        'sale_amount', mr.sale_amount,
        'fee_percent', mr.fee_percent,
        'fee_amount', mr.fee_amount,
        'box_cost_deducted', 0,
        'net_amount', mr.net_amount,
        'status', mr.status,
        'scheduled_date', null,
        'approved_at', null,
        'completed_at', mr.paid_at,
        'sold_at', mr.sold_at,
        'confirmed_at', null,
        'bank_name', null,
        'account_number', null,
        'account_holder', null,
        'account_last4', null,
        'created_at', mr.created_at
      ) as row_json,
      case mr.status when 'completed' then 1 else 3 end as status_rank,
      coalesce(mr.paid_at, mr.created_at) as sort_ts,
      'manual-' || mr.id::text as sort_id
    from manual_rows mr
  ),
  all_my_settlements as (
    select status, net_amount, completed_at
    from public.settlements
    where seller_user_id = v_user_id
    union all
    select status, net_amount, paid_at as completed_at
    from manual_rows
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(page.row_json order by page.status_rank, page.sort_ts desc nulls last, page.sort_id desc)
          from (
            select row_json, status_rank, sort_ts, sort_id
            from combined
            order by status_rank, sort_ts desc nulls last, sort_id desc
            offset greatest(0, coalesce(p_offset, 0))
            limit greatest(1, least(coalesce(p_limit, 50), 200))
          ) page
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
