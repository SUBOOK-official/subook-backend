-- 환불 신청 시 자동 구매확정 보류 (2026-08-24)
--
-- 배경: 구매자가 환불 신청(request_member_refund)을 해도 auto_confirm_delivered_orders가
--   refund_requested_at을 보지 않아 D+7에 그대로 confirmed 전이 → 정산(pending) 생성 →
--   셀러에게 "정산 예정" 알림톡까지 발송됐다. 환불정책 제6조("청약철회 신청 시 자동구매확정
--   및 정산 보류")와 코드 불일치. (송금은 admin_complete_settlements 가드가 최종 차단해
--   금전 사고는 없었음 — 혼선·정책 위반만 발생)
--
-- 설계: 보류는 "미해소 신청"에만 건다. 해소(refund_request_resolved_at) 시점 =
--   ① 환불 처리(전액/부분 — 환불 RPC가 자동 스탬프) 또는 ② 어드민 명시 반려
--   (admin_resolve_refund_request). 해소되면 다음 크론에서 자동확정 재개.
--
-- 변경 (컬럼 추가 + CREATE OR REPLACE — 데이터 비파괴):
--   1) orders.refund_request_resolved_at 추가 + 기처리분 백필
--   2) auto_confirm_delivered_orders: 미해소 환불 신청 주문 확정 보류
--   3) admin_refund_order / admin_refund_order_items: 환불 처리 시 해소 스탬프
--      (⚠ 본문은 20260824063025 반품 수거 버전 기반 — p_restock 분기·보류 스탬프 유지)
--   4) admin_resolve_refund_request: 신규 — 신청 반려(종결), 자동확정·송금 재개
--   5) admin_complete_settlements: 송금 차단을 미해소 신청으로 한정
--      (해소된 부분환불 주문의 잔여 품목 정산이 영구히 막히지 않게.
--       20260819065928 기반 — pending+approved 수용·transfer_reference·enrichment 유지)
--   6) get_admin_order_summary: refund_pending_count도 미해소 기준으로
--   7) list_admin_orders: refund_request_resolved_at 노출 + 우선 정렬을 미해소 기준으로

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) orders.refund_request_resolved_at + 백필
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists refund_request_resolved_at timestamptz null;

comment on column public.orders.refund_request_resolved_at is
  '환불 신청 해소 시각 — 환불 처리(전액/부분) 시 자동 스탬프 또는 admin_resolve_refund_request(반려). null이면 자동 구매확정·정산 송금 보류';

-- 백필: 이미 환불이 처리된(전액 refunded 또는 부분환불 누계 존재) 신청은 해소된 것으로 간주.
-- 미처리 신청은 null 유지 = 이번 배포부터 보류 대상 (의도된 동작).
update public.orders
   set refund_request_resolved_at = coalesce(refunded_at, updated_at, now())
 where refund_requested_at is not null
   and refund_request_resolved_at is null
   and (status = 'refunded' or coalesce(refunded_amount, 0) > 0);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) auto_confirm_delivered_orders — 미해소 환불 신청 주문은 확정 보류
--    (20260702130000 최신 정의 기반 — 매월 1일 정산 예정일·셀러 수집 유지)
-- ─────────────────────────────────────────────────────────────────────────────
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
      -- ⚠ 미해소 환불 신청은 확정 보류 (환불정책 제6조) — 환불 처리 또는 반려 시 재개
      and (refund_requested_at is null or refund_request_resolved_at is not null)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 3-1) admin_refund_order_items — 환불 처리 시 신청 해소 스탬프
--      (20260824063025 정의 기반, orders UPDATE에 해소 스탬프 1줄 추가)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_refund_order_items(
  p_order_id bigint,
  p_order_item_ids bigint[],
  p_refund_amount integer default null,
  p_reason text default null,
  p_acknowledge_recovery boolean default false,
  p_validate_only boolean default false,
  p_restock boolean default true
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
  v_held_books integer := 0;
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

  if coalesce(p_restock, true) then
    -- 재고 복원: reserved → on_sale + is_public=true (settled 책 제외 — 전액 환불과 동일 정책)
    update public.books b
       set status = 'on_sale', is_public = true
     where b.id in (
         select oi.book_id from public.order_items oi where oi.id = any(v_item_ids)
       )
       and b.status = 'reserved';
    get diagnostics v_restored_books = row_count;
  else
    -- 재입고 보류 (반품 수거 대기): 실물 미회수 상태에서 재노출 방지.
    -- 이번에 환불되는 품목에만 스탬프 — 회수 후 admin_confirm_return_recovery가 복원/폐기.
    update public.order_items oi
       set restock_held_at = v_now
     where oi.id = any(v_item_ids)
       and exists (
         select 1 from public.books b where b.id = oi.book_id and b.status = 'reserved'
       );
    get diagnostics v_held_books = row_count;
  end if;

  -- 주문 반영: 누계 가산, 모든 품목 환불 완료 시 주문 자체를 refunded로 전이.
  -- 환불 처리 자체가 신청 해소 — 미해소 신청으로 남아 자동확정이 영구 보류되는 것을 방지.
  update public.orders
     set refunded_amount = coalesce(refunded_amount, 0) + v_amount,
         status = case when v_is_final then 'refunded' else status end,
         payment_status = case
           when v_is_final and payment_status = 'paid' then 'refunded'
           else payment_status
         end,
         refunded_at = case when v_is_final then v_now else refunded_at end,
         refund_reason = case when v_is_final then coalesce(v_reason, refund_reason) else refund_reason end,
         refund_request_resolved_at = case
           when refund_requested_at is not null then coalesce(refund_request_resolved_at, v_now)
           else refund_request_resolved_at
         end,
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
    'held_books', v_held_books,
    'remaining_refundable', v_remaining - v_amount,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3-2) admin_refund_order — 환불 처리 시 신청 해소 스탬프 (20260824063025 기반)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_refund_order(
  p_order_id bigint,
  p_reason text default null,
  p_acknowledge_recovery boolean default false,
  p_restock boolean default true
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
  v_held_books integer := 0;
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
    refund_request_resolved_at = case
      when refund_requested_at is not null then coalesce(refund_request_resolved_at, v_now)
      else refund_request_resolved_at
    end,
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

  if coalesce(p_restock, true) then
    -- reserved 책을 on_sale + is_public=true로 같이 복원 (settled 책은 정산 처리됐으므로 제외)
    update public.books
    set status = 'on_sale', is_public = true
    where id in (
      select oi.book_id from public.order_items oi where oi.order_id = p_order_id
    )
    and status = 'reserved';
    get diagnostics v_restored_books = row_count;
  else
    -- 재입고 보류 (반품 수거 대기). 이번 호출로 환불된 품목(refunded_at = v_now)에만 스탬프 —
    -- 이전 부분환불에서 이미 복원된 책이 다른 주문에 reserved된 경우를 건드리지 않기 위함.
    update public.order_items oi
       set restock_held_at = v_now
     where oi.order_id = p_order_id
       and oi.refunded_at = v_now
       and exists (
         select 1 from public.books b where b.id = oi.book_id and b.status = 'reserved'
       );
    get diagnostics v_held_books = row_count;
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'cancelled_settlements', v_cancelled_settlements,
    'recovery_required_settlements', v_recovery_settlements,
    'restored_books', v_restored_books,
    'held_books', v_held_books,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) admin_resolve_refund_request — 신청 반려(종결): 자동확정·정산 송금 재개
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_resolve_refund_request(
  p_order_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order record;
  v_now timestamptz := now();
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.refund_requested_at is null then
    raise exception '환불 신청이 접수된 주문이 아닙니다.';
  end if;
  if v_order.status = 'refunded' then
    raise exception '이미 환불 처리된 주문입니다.';
  end if;
  if v_order.refund_request_resolved_at is not null then
    raise exception '이미 처리된 신청입니다. (해소일: %)',
      to_char(v_order.refund_request_resolved_at, 'YYYY-MM-DD HH24:MI');
  end if;

  update public.orders
     set refund_request_resolved_at = v_now,
         updated_at = v_now
   where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'resolved_at', v_now,
    -- 확정 예정 시각이 이미 지났으면 다음 크론(매시)에서 바로 확정된다
    'auto_confirm_resumes_now', (
      v_order.status = 'delivered'
      and v_order.auto_confirm_at is not null
      and v_order.auto_confirm_at <= v_now
    )
  );
end;
$$;

grant execute on function public.admin_resolve_refund_request(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) admin_complete_settlements — 송금 차단을 "미해소 신청"으로 한정
--    (20260819065928 기반 — pending+approved 수용·transfer_reference·enrichment·
--     books settled 전환 유지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_complete_settlements(
  p_settlement_ids bigint[],
  p_transfer_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_blocked_count integer;
  v_blocked_orders text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- ⚠ 미해소 환불 신청(refund_requested_at 있고 아직 환불 처리/반려 안 됨) 주문에
  --    묶인 settlement는 송금 차단. 해소(부분환불 처리·반려) 후에는 잔여 품목 정산 송금 가능.
  select count(*)::integer, string_agg(distinct o.order_number, ', ')
    into v_blocked_count, v_blocked_orders
  from public.settlements st
  inner join public.orders o on o.id = st.order_id
  where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
    and st.status in ('pending', 'approved')
    and o.refund_requested_at is not null
    and o.refund_request_resolved_at is null
    and o.status <> 'refunded';

  if coalesce(v_blocked_count, 0) > 0 then
    raise exception '환불 신청이 접수된 주문이 포함되어 송금을 진행할 수 없습니다. (주문번호: %) 환불 처리 또는 신청 반려를 먼저 완료해주세요.',
      v_blocked_orders;
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
      -- 승인 단계 폐지: 정산대기(pending)도 송금 후 바로 완료 처리 (approved는 레거시 행)
      and st.status in ('pending', 'approved')
  ),
  updated as (
    update public.settlements st
    set
      status = 'completed',
      completed_at = now(),
      transfer_reference = coalesce(nullif(btrim(p_transfer_reference), ''), st.transfer_reference),
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
  enriched as (
    -- 알림톡 발송용 필드 (회원 프로필 우선, 없으면 shipment 스냅샷)
    select
      u.*,
      o.order_number,
      coalesce(oi.title, b.title) as book_title,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as resolved_seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as resolved_seller_phone
    from updated u
    left join public.orders o on o.id = u.order_id
    left join public.order_items oi on oi.id = u.order_item_id
    left join public.books b on b.id = u.book_id
    left join public.shipments sh on sh.id = b.shipment_id
    left join public.member_profiles mp on mp.user_id = u.seller_user_id
  ),
  result_rows as (
    select
      jsonb_agg(
        jsonb_build_object(
          'id', e.id,
          'order_id', e.order_id,
          'order_number', e.order_number,
          'book_title', e.book_title,
          'seller_user_id', e.seller_user_id,
          'seller_name', e.resolved_seller_name,
          'seller_phone', e.resolved_seller_phone,
          'net_amount', e.net_amount,
          'bank_name', e.bank_name,
          'account_last4', public.get_account_last4(e.account_number),
          'transfer_reference', e.transfer_reference,
          'status', e.status,
          'completed_at', e.completed_at
        )
        order by e.completed_at desc nulls last, e.id desc
      ) as items,
      count(*)::integer as count
    from enriched e
  )
  select jsonb_build_object(
    'success', true,
    'completed_count', coalesce(r.count, 0),
    'settlements', coalesce(r.items, '[]'::jsonb)
  )
  into v_result
  from result_rows r;

  return coalesce(v_result, jsonb_build_object('success', true, 'completed_count', 0, 'settlements', '[]'::jsonb));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) get_admin_order_summary — refund_pending_count를 미해소 기준으로
--    (20260525190000 기반)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_admin_order_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  return jsonb_build_object(
    'total_count', (select count(*) from public.orders),
    'pending_count', (select count(*) from public.orders where status = 'pending'),
    'paid_count', (select count(*) from public.orders where status = 'paid'),
    'preparing_count', (select count(*) from public.orders where status = 'preparing'),
    'shipping_count', (select count(*) from public.orders where status = 'shipping'),
    'delivered_count', (select count(*) from public.orders where status = 'delivered'),
    'confirmed_count', (select count(*) from public.orders where status = 'confirmed'),
    'cancelled_count', (select count(*) from public.orders where status = 'cancelled'),
    -- 환불 신청 접수됐지만 아직 처리(환불/반려) 안 된 큐
    'refund_pending_count', (
      select count(*) from public.orders
      where refund_requested_at is not null
        and refund_request_resolved_at is null
        and status <> 'refunded'
    )
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) list_admin_orders — refund_request_resolved_at 노출 + 우선 정렬 미해소 기준
--    (20260824063025 반품 수거 버전 기반 — 피킹 메타·is_guest·return_*·restock_held_at 유지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_admin_orders(
  p_search text default null::text,
  p_statuses text[] default null::text[],
  p_from_date date default null::date,
  p_to_date date default null::date,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
      o.shipping_recipient_name ilike '%' || p_search || '%' or
      o.shipping_recipient_phone ilike '%' || p_search || '%')
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
      -- 환불 신청 해소 시각 (2026-08-24 자동확정 보류 — null이면 확정·송금 보류 중)
      'refund_request_resolved_at', o.refund_request_resolved_at,
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- 반품 수거 3종 (2026-08-24 반품 수거 자동화 — cust_use_no는 서버 전용이라 미노출)
      'return_tracking_number', o.return_tracking_number,
      'return_registered_at', o.return_registered_at,
      'return_recovered_at', o.return_recovered_at,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      -- 비회원 주문 여부 (2026-08-03 게스트 주문 도입)
      'is_guest', (o.user_id is null),
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
          -- 재입고 보류 (2026-08-24 반품 수거 — 실물 회수 전 재노출 방지)
          'restock_held_at', oi.restock_held_at,
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
        o.shipping_recipient_name ilike '%' || p_search || '%' or
        o.shipping_recipient_phone ilike '%' || p_search || '%')
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= p_from_date)
      and (p_to_date is null or o.created_at < p_to_date + interval '1 day')
    order by
      -- 미해소 환불 신청 최우선 (해소된 신청은 일반 정렬)
      (case
        when o.refund_requested_at is not null
         and o.refund_request_resolved_at is null
         and o.status <> 'refunded' then 0
        else 1
      end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$function$;

commit;

notify pgrst, 'reload schema';
