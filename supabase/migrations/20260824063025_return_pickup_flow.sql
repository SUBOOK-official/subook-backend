-- 반품 수거 자동화 (2026-08-24)
--
-- 배경: 배송완료 후 환불 시 실물 회수 플로우가 없었다. 환불 RPC가 reserved 책을
--   즉시 on_sale + is_public=true로 복원해, 책이 아직 구매자 집에 있는데 스토어에
--   재노출되는 문제(다른 구매자가 사면 실물 없는 주문). CJ 반품 접수(방문 수거)도
--   시스템에 없어 전부 수동이었다.
--
-- 변경 (컬럼 추가 + RPC 재정의 — 데이터 비파괴):
--   1) orders 반품 수거 컬럼 3종: return_tracking_number / return_cust_use_no /
--      return_registered_at (+회수 확인 시각 return_recovered_at)
--   2) order_items.restock_held_at — 재입고 보류 스탬프 (환불됐지만 실물 미회수)
--   3) admin_refund_order / admin_refund_order_items — p_restock 파라미터 추가.
--      false면 reserved 책을 복원하지 않고 이번에 환불되는 품목에만 보류 스탬프.
--      (⚠ 시그니처 변경이라 기존 함수 drop 후 재생성 — 나머지 본문은 20260731174237
--       현행과 동일: validate_only·RECOVERY_REQUIRED_ACK·정산 cancelled/recovery·
--       쿠폰 복구 정책 전부 유지)
--   4) admin_confirm_return_recovery — 회수 확인: 보류 품목의 책을 재판매 복원
--      또는 폐기 처리하고 보류 스탬프 해제
--   5) books_assert_no_active_order_on_discard — 품목별 부분환불(2026-08-01) 반영.
--      환불된 품목은 활성 주문으로 세지 않는다 (부분환불 품목 책 폐기가 막히던 구멍)
--   6) list_admin_orders — 반품 수거 필드 노출 (20260803061500 게스트 버전 기반,
--      ⚠ 재정의 시 피킹 메타·user_id·is_guest·환불 필드 유지 필수)
--
-- 보류 스탬프를 book 상태 추론이 아니라 컬럼으로 두는 이유: 책이 복원 후 다른 주문에
-- 다시 reserved될 수 있어, "환불 품목 + reserved" 추론은 남의 주문 책을 되돌릴 위험이 있다.
-- 보류된 책은 on_sale로 풀리지 않으므로 다른 주문이 잡을 수 없다 = 스탬프 기반은 안전.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) orders — CJ 반품 수거 접수·회수 확인 메타
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists return_tracking_number text null,
  add column if not exists return_cust_use_no text null,
  add column if not exists return_registered_at timestamptz null,
  add column if not exists return_recovered_at timestamptz null;

comment on column public.orders.return_tracking_number is
  'CJ 반품 수거 운송장번호 (구매자→수북 역방향, cj-return.js 채번)';
comment on column public.orders.return_cust_use_no is
  'CJ 반품 접수 고객사용번호 (접수 PK 매칭용 — CnclBook 취소 시 이 값으로 대상 지정)';
comment on column public.orders.return_registered_at is
  'CJ 반품 수거 접수 시각 (취소 시 null로 되돌림)';
comment on column public.orders.return_recovered_at is
  '반품 실물 회수 확인 시각 (admin_confirm_return_recovery)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) order_items.restock_held_at — 재입고 보류 스탬프
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.order_items
  add column if not exists restock_held_at timestamptz null;

comment on column public.order_items.restock_held_at is
  '환불 시 재입고 보류 스탬프 (p_restock=false). 실물 회수 후 admin_confirm_return_recovery가 해제';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3-1) admin_refund_order_items — p_restock 추가 (시그니처 변경 → drop 후 재생성)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_refund_order_items(bigint, bigint[], integer, text, boolean, boolean);

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
    'held_books', v_held_books,
    'remaining_refundable', v_remaining - v_amount,
    'refunded_at', v_now,
    'refund_reason', v_reason
  );
end;
$$;

grant execute on function public.admin_refund_order_items(bigint, bigint[], integer, text, boolean, boolean, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3-2) admin_refund_order — p_restock 추가 (시그니처 변경 → drop 후 재생성)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_refund_order(bigint, text, boolean);

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

grant execute on function public.admin_refund_order(bigint, text, boolean, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) admin_confirm_return_recovery — 회수 확인 (재판매 복원 / 폐기)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_confirm_return_recovery(
  p_order_id bigint,
  p_outcome text default 'restock'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_book_ids bigint[];
  v_updated_books integer := 0;
  v_cleared_items integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_outcome not in ('restock', 'discard') then
    raise exception '알 수 없는 처리 방식입니다: % (restock 또는 discard)', p_outcome;
  end if;

  perform 1 from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  -- 보류 품목의 책 — 보류된 책은 on_sale로 풀린 적이 없어 reserved가 이 주문 소유임이 보장된다.
  select coalesce(array_agg(distinct oi.book_id), '{}'::bigint[])
    into v_book_ids
    from public.order_items oi
    join public.books b on b.id = oi.book_id
   where oi.order_id = p_order_id
     and oi.restock_held_at is not null
     and b.status = 'reserved';

  if coalesce(array_length(v_book_ids, 1), 0) = 0 then
    raise exception '회수 보류 중인 책이 없습니다.';
  end if;

  if p_outcome = 'restock' then
    update public.books
       set status = 'on_sale', is_public = true
     where id = any(v_book_ids)
       and status = 'reserved';
  else
    -- 폐기: 회수한 실물이 훼손 등으로 재판매 불가한 경우.
    -- (books_assert_no_active_order_on_discard 가드는 환불된 품목을 활성으로 세지 않음 — 본 마이그레이션 5번)
    update public.books
       set status = 'discarded', is_public = false
     where id = any(v_book_ids)
       and status = 'reserved';
  end if;
  get diagnostics v_updated_books = row_count;

  update public.order_items
     set restock_held_at = null
   where order_id = p_order_id
     and restock_held_at is not null;
  get diagnostics v_cleared_items = row_count;

  update public.orders
     set return_recovered_at = v_now,
         updated_at = v_now
   where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'outcome', p_outcome,
    'updated_books', v_updated_books,
    'cleared_items', v_cleared_items,
    'recovered_at', v_now
  );
end;
$$;

grant execute on function public.admin_confirm_return_recovery(bigint, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) books_assert_no_active_order_on_discard — 품목별 부분환불 반영
--    (2026051506 원본은 주문 상태만 봐서, 부분환불된 품목의 책 폐기가
--     "주문이 아직 delivered/confirmed"라는 이유로 막혔다. 환불된 품목은 활성 아님.)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.books_assert_no_active_order_on_discard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active_count integer;
  v_is_discard_transition boolean;
begin
  v_is_discard_transition :=
    (coalesce(new.condition_grade, '') = 'DISCARD' and coalesce(old.condition_grade, '') <> 'DISCARD')
    or (coalesce(new.status, '') = 'discarded' and coalesce(old.status, '') <> 'discarded');

  if not v_is_discard_transition then
    return new;
  end if;

  select count(*) into v_active_count
  from public.order_items oi
  inner join public.orders o on o.id = oi.order_id
  where oi.book_id = new.id
    and o.status not in ('cancelled', 'refunded')
    -- 품목별 부분환불(2026-08-01) 반영: 환불된 품목은 활성 주문으로 세지 않는다
    and oi.refunded_at is null;

  if v_active_count > 0 then
    raise exception '활성 주문(% 건)이 있는 책은 폐기 처리할 수 없습니다. 환불 처리 후 다시 시도해 주세요.', v_active_count;
  end if;

  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) list_admin_orders — 반품 수거 필드 노출
--    (20260803061500 게스트 버전 기반 — 피킹 메타(book_serial_number/location/status)·
--     user_id·is_guest·환불 필드 유지 필수. 추가: 주문 return_* 3종 + 품목 restock_held_at)
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
      (case when o.refund_requested_at is not null and o.status <> 'refunded' then 0 else 1 end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$function$;

commit;

notify pgrst, 'reload schema';
