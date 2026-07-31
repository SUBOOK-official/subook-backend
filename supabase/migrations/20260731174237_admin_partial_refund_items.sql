-- 어드민 품목별 부분환불 (2026-08-01)
--
-- 배경: 기존 환불은 주문 전체 단위(admin_refund_order)만 가능. 여러 권 주문에서
--   1권만 반품하는 케이스를 처리할 수 없었다. 품목(order_items) 단위 부분환불을 도입한다.
--
-- 변경 (모두 비파괴 — 컬럼 추가 + CREATE OR REPLACE):
--   1) orders.refunded_amount        : 실제 환불된 금액 누계 (부분환불 진행 상태의 돈 기준값)
--   2) order_items.refunded_at/refund_amount/refund_reason : 품목별 환불 스탬프
--   3) admin_refund_order_items      : 신규 RPC — 품목 선택 환불 (검증 전용 모드 지원)
--   4) admin_refund_order            : 기존 전액 환불도 품목 스탬프·누계를 같이 기록 (drift 방지)
--   5) create_settlements_for_order  : 환불된 품목 제외 (부분환불 후 구매확정 시 셀러 오지급 방지)
--   6) list_admin_orders             : refunded_amount + 품목별 환불 필드 노출
--   7) 레거시 refunded 주문 백필     : 누계·품목 스탬프 소급
--
-- 돈 계산 정책:
--   - 환불 가능 잔액 = orders.total_amount - orders.refunded_amount (쿠폰 할인·배송비 반영된 실결제 기준)
--   - 기본 환불액 = 선택 품목 total_price 합 (잔액 캡). 남은 품목 없이 전부 선택하면
--     잔액 전액(배송비 포함) — 기존 전액 환불과 동일한 금액이 된다.
--   - 운영자가 금액을 직접 조정 가능(배송비 차감·쿠폰 몫 차감 등). 잔액 초과는 거부.
--   - 품목별 refund_amount는 배분값(총 환불액을 total_price 비례 배분, 끝수는 마지막 품목).
--     돈의 진실은 orders.refunded_amount 누계다.
--   - 쿠폰 복구는 "이 환불로 모든 품목이 환불 완료"가 될 때만 (기존 전액 환불과 동일 정책).
--
-- PG 부분취소 흐름(서버리스 payment-cancel.js)은 p_validate_only=true로 먼저 검증만 하고
-- (RECOVERY_REQUIRED_ACK 포함), PG 취소 성공 후 p_validate_only=false로 확정한다.
-- → PG 취소 전에 DB가 거부 사유를 다 걸러내므로 "PG는 취소됐는데 DB가 막힘" 재시도 이중취소를 구조적으로 방지.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) orders.refunded_amount — 환불 누계
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists refunded_amount integer not null default 0;

alter table public.orders drop constraint if exists orders_refunded_amount_check;
alter table public.orders add constraint orders_refunded_amount_check
  check (refunded_amount >= 0 and refunded_amount <= total_amount);

comment on column public.orders.refunded_amount is
  '실제 환불된 금액 누계 (부분환불 포함). 환불 가능 잔액 = total_amount - refunded_amount';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) order_items 품목별 환불 스탬프
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.order_items
  add column if not exists refunded_at timestamptz null,
  add column if not exists refund_amount integer null,
  add column if not exists refund_reason text null;

alter table public.order_items drop constraint if exists order_items_refund_amount_check;
alter table public.order_items add constraint order_items_refund_amount_check
  check (refund_amount is null or refund_amount >= 0);

comment on column public.order_items.refund_amount is
  '이 품목에 배분된 환불액 (부분환불 시 total_price 비례 배분). 레거시 전액 환불 백필분은 null — 주문 refunded_amount가 기준';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) admin_refund_order_items — 품목 선택 부분환불 RPC
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_refund_order_items(
  p_order_id bigint,
  p_order_item_ids bigint[],
  p_refund_amount integer default null,
  p_reason text default null,
  p_acknowledge_recovery boolean default false,
  p_validate_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_now timestamptz := now();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_item_ids bigint[];
  v_selected_count integer;
  v_already_refunded integer;
  v_items_total bigint;
  v_remaining integer;
  v_unrefunded_left integer;
  v_is_final boolean;
  v_amount integer;
  v_item record;
  v_alloc integer;
  v_allocated integer := 0;
  v_idx integer := 0;
  v_cancelled_settlements integer := 0;
  v_recovery_settlements integer := 0;
  v_restored_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 입력 정리 (중복 제거)
  select coalesce(array_agg(distinct t.x), '{}'::bigint[])
    into v_item_ids
    from unnest(coalesce(p_order_item_ids, '{}'::bigint[])) as t(x);
  if coalesce(array_length(v_item_ids, 1), 0) = 0 then
    raise exception '환불할 품목을 1개 이상 선택해주세요.';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status in ('cancelled', 'refunded') then
    raise exception '이미 취소/환불된 주문입니다. (현재: %)', v_order.status;
  end if;
  if v_order.status = 'pending' then
    raise exception '결제 확인 전(입금대기) 주문은 환불이 아니라 주문취소로 처리해주세요.';
  end if;

  -- 선택 품목 검증: 이 주문 소속 + 아직 미환불
  select count(*)::integer,
         count(*) filter (where oi.refunded_at is not null),
         coalesce(sum(oi.total_price) filter (where oi.refunded_at is null), 0)
    into v_selected_count, v_already_refunded, v_items_total
    from public.order_items oi
   where oi.order_id = p_order_id
     and oi.id = any(v_item_ids);

  if v_selected_count <> array_length(v_item_ids, 1) then
    raise exception '이 주문에 속하지 않는 품목이 포함되어 있습니다.';
  end if;
  if v_already_refunded > 0 then
    raise exception '이미 환불된 품목이 포함되어 있습니다. (%건)', v_already_refunded;
  end if;

  v_remaining := coalesce(v_order.total_amount, 0) - coalesce(v_order.refunded_amount, 0);

  -- 이번 선택 이후에도 미환불로 남는 품목 수 → 0이면 사실상 전액 환불
  select count(*)::integer into v_unrefunded_left
    from public.order_items oi
   where oi.order_id = p_order_id
     and oi.refunded_at is null
     and not (oi.id = any(v_item_ids));
  v_is_final := (v_unrefunded_left = 0);

  -- 환불 금액: 미지정 시 품목 합 (전부 선택이면 잔액 전액 = 배송비 포함), 잔액 한도 캡
  v_amount := coalesce(
    p_refund_amount,
    case when v_is_final then v_remaining else least(v_items_total::integer, v_remaining) end
  );
  if v_amount is null or v_amount <= 0 then
    raise exception '환불 금액이 올바르지 않습니다. (남은 환불 가능 금액: %원)', v_remaining;
  end if;
  if v_amount > v_remaining then
    raise exception '환불 금액이 남은 환불 가능 금액을 초과합니다. (요청 %원 / 가능 %원)', v_amount, v_remaining;
  end if;

  -- 송금 완료 정산 가드 — 선택 품목에 한해 검사 (전액 환불의 RECOVERY_REQUIRED_ACK와 동일 정책)
  if not coalesce(p_acknowledge_recovery, false) then
    if exists (
      select 1
        from public.settlements st
        join public.order_items oi
          on oi.order_id = st.order_id and oi.book_id = st.book_id
       where st.order_id = p_order_id
         and st.status = 'completed'
         and oi.id = any(v_item_ids)
    ) then
      raise exception 'RECOVERY_REQUIRED_ACK: 선택한 품목 중 셀러에게 정산금이 이미 송금 완료된 건이 있습니다. 환불 시 회수가 불가능하여 회사 손실로 처리됩니다.';
    end if;
  end if;

  -- 검증 전용 모드: PG 취소 전에 거부 사유를 전부 걸러내기 위한 호출. 어떤 변경도 하지 않는다.
  if p_validate_only then
    return jsonb_build_object(
      'success', true,
      'validated', true,
      'order_id', p_order_id,
      'refund_amount', v_amount,
      'items_total', v_items_total,
      'order_fully_refunded', v_is_final,
      'remaining_refundable', v_remaining
    );
  end if;

  -- 품목별 환불액 배분: total_price 비례, 끝수는 마지막 품목이 흡수
  for v_item in
    select oi.id, oi.total_price
      from public.order_items oi
     where oi.order_id = p_order_id
       and oi.id = any(v_item_ids)
     order by oi.id
  loop
    v_idx := v_idx + 1;
    if v_idx = array_length(v_item_ids, 1) then
      v_alloc := v_amount - v_allocated;
    elsif v_items_total > 0 then
      v_alloc := floor(v_amount::numeric * v_item.total_price / v_items_total)::integer;
    else
      v_alloc := 0;
    end if;
    v_allocated := v_allocated + v_alloc;

    update public.order_items
       set refunded_at = v_now,
           refund_amount = v_alloc,
           refund_reason = v_reason
     where id = v_item.id;
  end loop;

  -- 정산 처리 — 선택 품목의 책 기준 (settlements는 (order_id, book_id) 유니크)
  update public.settlements st
     set status = 'cancelled',
         cancelled_at = v_now,
         refund_reason = v_reason,
         updated_at = v_now
   where st.order_id = p_order_id
     and st.status in ('pending', 'approved')
     and st.book_id in (
       select oi.book_id from public.order_items oi where oi.id = any(v_item_ids)
     );
  get diagnostics v_cancelled_settlements = row_count;

  update public.settlements st
     set status = 'recovery_required',
         recovery_required_at = v_now,
         refund_reason = v_reason,
         updated_at = v_now
   where st.order_id = p_order_id
     and st.status = 'completed'
     and st.book_id in (
       select oi.book_id from public.order_items oi where oi.id = any(v_item_ids)
     );
  get diagnostics v_recovery_settlements = row_count;

  -- 재고 복원: reserved → on_sale + is_public=true (settled 책 제외 — 전액 환불과 동일 정책)
  update public.books b
     set status = 'on_sale', is_public = true
   where b.id in (
       select oi.book_id from public.order_items oi where oi.id = any(v_item_ids)
     )
     and b.status = 'reserved';
  get diagnostics v_restored_books = row_count;

  -- 주문 반영: 누계 가산, 모든 품목 환불 완료 시 주문 자체를 refunded로 전이
  update public.orders
     set refunded_amount = coalesce(refunded_amount, 0) + v_amount,
         status = case when v_is_final then 'refunded' else status end,
         payment_status = case
           when v_is_final and payment_status = 'paid' then 'refunded'
           else payment_status
         end,
         refunded_at = case when v_is_final then v_now else refunded_at end,
         refund_reason = case when v_is_final then coalesce(v_reason, refund_reason) else refund_reason end,
         updated_at = v_now
   where id = p_order_id;

  -- 전액 환불 도달 시에만 쿠폰 복구 (부분환불 중에는 쿠폰 혜택이 잔여 품목에 계속 적용된 상태)
  if v_is_final and v_order.applied_member_coupon_id is not null then
    update public.member_coupons
       set used_at = null,
           used_order_id = null,
           status = case
             when expires_at is not null and expires_at < now() then 'expired'
             else 'available'
           end,
           updated_at = now()
     where id = v_order.applied_member_coupon_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'refund_amount', v_amount,
    'refunded_item_count', array_length(v_item_ids, 1),
    'order_fully_refunded', v_is_final,
    'cancelled_settlements', v_cancelled_settlements,
    'recovery_required_settlements', v_recovery_settlements,
    'restored_books', v_restored_books,
    'remaining_refundable', v_remaining - v_amount,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

grant execute on function public.admin_refund_order_items(bigint, bigint[], integer, text, boolean, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) admin_refund_order — 기존 전액 환불도 품목 스탬프 + 누계 기록 (drift 방지)
--    (20260531000000 ack_guard 최신 정의 기반, 품목/누계 반영 2블록만 추가)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_refund_order(
  p_order_id bigint,
  p_reason text default null,
  p_acknowledge_recovery boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_now timestamptz := now();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_cancelled_settlements integer := 0;
  v_recovery_settlements integer := 0;
  v_restored_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status in ('cancelled', 'refunded') then
    raise exception '이미 취소/환불된 주문입니다. (현재: %)', v_order.status;
  end if;

  -- ⚠ 이미 셀러에게 송금 완료(completed)된 정산이 있으면 환불 시 회수가 사실상 불가능 = 회사 손실.
  --    운영자가 명시적으로 손실을 감수(p_acknowledge_recovery=true)하지 않으면 차단한다.
  if not coalesce(p_acknowledge_recovery, false) then
    if exists (
      select 1 from public.settlements
      where order_id = p_order_id and status = 'completed'
    ) then
      raise exception 'RECOVERY_REQUIRED_ACK: 이미 셀러에게 정산금이 송금 완료된 주문입니다. 환불 시 회수가 불가능하여 회사 손실로 처리됩니다.';
    end if;
  end if;

  -- 품목 스탬프 (부분환불과 상태 일관성 유지 — refund_amount는 주문 단위 환불이라 null)
  update public.order_items
     set refunded_at = v_now,
         refund_reason = v_reason
   where order_id = p_order_id
     and refunded_at is null;

  update public.orders
  set
    status = 'refunded',
    payment_status = case when payment_status = 'paid' then 'refunded' else payment_status end,
    refunded_amount = total_amount,
    refunded_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where id = p_order_id;

  update public.settlements
  set
    status = 'cancelled',
    cancelled_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where order_id = p_order_id
    and status in ('pending', 'approved');
  get diagnostics v_cancelled_settlements = row_count;

  update public.settlements
  set
    status = 'recovery_required',
    recovery_required_at = v_now,
    refund_reason = v_reason,
    updated_at = v_now
  where order_id = p_order_id
    and status = 'completed';
  get diagnostics v_recovery_settlements = row_count;

  if v_order.applied_member_coupon_id is not null then
    update public.member_coupons
    set used_at = null,
        used_order_id = null,
        status = case
          when expires_at is not null and expires_at < now() then 'expired'
          else 'available'
        end,
        updated_at = now()
    where id = v_order.applied_member_coupon_id;
  end if;

  -- reserved 책을 on_sale + is_public=true로 같이 복원 (settled 책은 정산 처리됐으므로 제외)
  update public.books
  set status = 'on_sale', is_public = true
  where id in (
    select oi.book_id from public.order_items oi where oi.order_id = p_order_id
  )
  and status = 'reserved';
  get diagnostics v_restored_books = row_count;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'cancelled_settlements', v_cancelled_settlements,
    'recovery_required_settlements', v_recovery_settlements,
    'restored_books', v_restored_books,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

grant execute on function public.admin_refund_order(bigint, text, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) create_settlements_for_order — 환불된 품목 제외
--    (20260702130000 최신 정의 기반, item 루프 where에 refunded_at is null 1줄 추가.
--     부분환불 후 구매확정되면 환불된 책까지 셀러 정산이 생성되던 구멍을 막는다.
--     ⚠ 재정의 시 이 필터 + 박스비 차감·매월 1일 정산 로직 유지 필수)
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
-- 6) list_admin_orders — refunded_amount + 품목별 환불 필드 노출
--    (20260717193926 최신 정의 기반 — 피킹 메타(book_serial_number/location/status) 유지 필수)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_admin_orders(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_items jsonb;
  v_total integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
  from public.orders o
  left join public.member_profiles p on p.user_id = o.user_id
  where
    (p_search is null or p_search = '' or
      o.order_number ilike '%' || p_search || '%' or
      p.name ilike '%' || p_search || '%' or
      p.email ilike '%' || p_search || '%' or
      p.phone ilike '%' || p_search || '%' or
      o.shipping_recipient_name ilike '%' || p_search || '%')
    and (p_statuses is null or o.status = any(p_statuses))
    and (p_from_date is null or o.created_at >= p_from_date)
    and (p_to_date is null or o.created_at < p_to_date + interval '1 day');

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      -- 결제 확인 시각 2종 (2026-07-13: 무통장=paid_at, 레거시 PG=pg_approved_at 폴백)
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      -- 할인 필드 3종 (2026-07-06 피드백: 주문 상세에 쿠폰 사용액 표시)
      'discount_amount', o.discount_amount,
      'coupon_discount_amount', o.coupon_discount_amount,
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'shipping_recipient_name', o.shipping_recipient_name,
      'shipping_recipient_phone', o.shipping_recipient_phone,
      'shipping_postal_code', o.shipping_postal_code,
      'shipping_address_line1', o.shipping_address_line1,
      'shipping_address_line2', o.shipping_address_line2,
      'shipping_memo', o.shipping_memo,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      -- 환불 메타 4종
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      'buyer_email', p.email,
      'buyer_name', p.name,
      'buyer_phone', p.phone,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          -- 품목별 환불 상태 (2026-08-01 부분환불)
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount,
          'refund_reason', oi.refund_reason,
          -- 피킹 동선용 재고 메타 (2026-07-18: 위치로 가서 일련번호로 실물 확인)
          'book_serial_number', b.serial_number,
          'book_location', b.location,
          'book_status', b.status
        ) order by oi.id)
        from public.order_items oi
        left join public.books b on b.id = oi.book_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    left join public.member_profiles p on p.user_id = o.user_id
    where
      (p_search is null or p_search = '' or
        o.order_number ilike '%' || p_search || '%' or
        p.name ilike '%' || p_search || '%' or
        p.email ilike '%' || p_search || '%' or
        p.phone ilike '%' || p_search || '%' or
        o.shipping_recipient_name ilike '%' || p_search || '%')
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= p_from_date)
      and (p_to_date is null or o.created_at < p_to_date + interval '1 day')
    order by
      (case when o.refund_requested_at is not null and o.status <> 'refunded' then 0 else 1 end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) 레거시 전액 환불 주문 백필 — 누계·품목 스탬프 소급
--    (품목 refund_amount는 null 유지 — 당시 실제 배분 금액을 알 수 없고,
--     돈의 진실은 orders.refunded_amount = total_amount 로 충분)
-- ─────────────────────────────────────────────────────────────────────────────
update public.orders o
   set refunded_amount = o.total_amount
 where o.status = 'refunded'
   and coalesce(o.refunded_amount, 0) = 0
   and o.total_amount > 0;

update public.order_items oi
   set refunded_at = coalesce(o.refunded_at, o.updated_at, now()),
       refund_reason = o.refund_reason
  from public.orders o
 where o.id = oi.order_id
   and o.status = 'refunded'
   and oi.refunded_at is null;

commit;

notify pgrst, 'reload schema';
