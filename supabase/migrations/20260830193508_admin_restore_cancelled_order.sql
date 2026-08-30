-- 취소된 미결제 주문 복원 (어드민 셀프 서비스)
--
-- 배경(2026-08-31): ORD-2608-0182(권재윤) — 무통장 입금이 실제로 들어왔는데 운영자가
--   입금확인 클릭을 24시간 안에 못 해서 expire_unpaid_orders()가 자동취소해 버렸다.
--   되살릴 수단이 어드민에 전혀 없어 DB 직접 수정 외엔 방법이 없었음. 앞으로도 반복될
--   유형(주말·야간 입금)이라 어드민 버튼 한 번으로 끝나게 만든다.
--
-- 변경 (비파괴):
--   1) orders.restored_at / restored_by 컬럼 추가 — 복원 이력 + "결제 대기 시계" 기준점.
--   2) expire_unpaid_orders(): 만료·리마인더 기준 시각을 created_at → 복원 시각 우선
--      (greatest(created_at, restored_at))으로 교체. 이게 없으면 24시간 지난 주문을
--      복원한 직후 15분 크론이 다시 취소해 버린다(복원 무한 무효화).
--   3) admin_restore_cancelled_order(p_order_id, p_validate_only): 취소 주문을
--      pending(입금대기)으로 되돌리고 책을 다시 선점 + 쿠폰 재소진.
--      복원 후 운영자가 기존 '입금확인' 버튼을 누르면 preparing으로 정상 전이되고
--      시트 기록·알림톡도 평소 경로 그대로 발화한다(별도 우회 경로를 만들지 않음).
--   4) list_admin_orders(): restored_at 노출 (어드민 상세에 복원 이력 표시).
--
-- 복원 금지(hard guard):
--   · status <> 'cancelled'
--   · 실제 결제 이력 있음(paid_at / payment_key / refunded_at / refunded_amount>0)
--     → 환불 완료건을 되살리면 PG·입금 정합이 깨진다. 새 주문으로 진행.
--   · 책이 이미 팔렸거나(settled) 폐기(discarded)됐거나 다른 활성 주문이 선점
--   · 쿠폰이 그 사이 다른 주문에 사용됨
--   위 3·4번은 예외 대신 blocked 목록을 돌려줘 어드민이 사유를 그대로 보여준다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 복원 메타 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists restored_at timestamptz,
  add column if not exists restored_by uuid;

comment on column public.orders.restored_at is
  '취소 주문 복원 시각. 미결제 만료(expire_unpaid_orders) 기준 시계로도 쓰인다 — 복원 시점부터 24시간 재부여.';
comment on column public.orders.restored_by is
  '복원을 실행한 어드민 auth.uid().';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) expire_unpaid_orders — 만료/리마인더 기준 시각에 restored_at 반영
--    (base: 20260803052801 — 세션 청소 포함. 시그니처 동일 CREATE OR REPLACE)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.expire_unpaid_orders()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_count   integer := 0;
  v_coupon_restored integer := 0;
  v_reminded_count  integer := 0;
  v_sessions_purged integer := 0;
  v_iter_count      integer;
  v_order           record;
begin
  -- 1) 입금 마감 임박 리마인더 (마감 3시간 전 ~ 마감 전, 1회) — 무통장 전용
  --    기준 시각 = greatest(created_at, restored_at): 복원된 주문은 복원 시점부터 다시 24시간.
  with target as (
    select o.id, o.user_id, o.order_number,
           greatest(o.created_at, coalesce(o.restored_at, o.created_at)) as clock_at
    from public.orders o
    where o.status = 'pending'
      and o.payment_status = 'pending'
      and coalesce(o.payment_method, 'bank_transfer') = 'bank_transfer'
      and o.payment_reminder_sent_at is null
      and o.user_id is not null
      and greatest(o.created_at, coalesce(o.restored_at, o.created_at)) < now() - interval '21 hours'
      and greatest(o.created_at, coalesce(o.restored_at, o.created_at)) >= now() - interval '24 hours'
    for update skip locked
  ),
  notified as (
    insert into public.member_notifications (user_id, type, title, body, ref_url, ref_type, ref_id)
    select
      t.user_id,
      'order',
      '입금 마감이 다가오고 있어요',
      format(
        '주문 %s의 입금이 아직 확인되지 않았어요. %s까지 입금되지 않으면 주문이 자동 취소됩니다.',
        t.order_number,
        to_char((t.clock_at + interval '24 hours') at time zone 'Asia/Seoul', 'MM/DD HH24:MI')
      ),
      '/order/complete/' || t.id,
      'order',
      t.id
    from target t
    returning 1
  )
  update public.orders o
     set payment_reminder_sent_at = now()
    from target t
   where o.id = t.id;

  get diagnostics v_reminded_count = row_count;

  -- 2) 미결제 주문 자동 취소 + 쿠폰 복구
  --    · 무통장: 24시간 (입금 대기)
  --    · 카드(비무통장): 30분 — 선주문 생성 폐지(20260803) 후엔 "finalize 후 승인 전
  --      서버 크래시"로 남은 고아 pending의 백스톱 (정상 흐름에선 거의 발생 안 함)
  --    복원된 주문(restored_at)은 복원 시각부터 다시 카운트 — 안 그러면 복원 즉시 재취소된다.
  for v_order in
    select id, applied_member_coupon_id
      from public.orders
     where status = 'pending'
       and payment_status = 'pending'
       and (
         greatest(created_at, coalesce(restored_at, created_at)) < now() - interval '24 hours'
         or (
           coalesce(payment_method, 'bank_transfer') <> 'bank_transfer'
           and greatest(created_at, coalesce(restored_at, created_at)) < now() - interval '30 minutes'
         )
       )
  loop
    update public.orders
       set status = 'cancelled',
           payment_status = 'refunded',
           updated_at = now()
     where id = v_order.id;

    if v_order.applied_member_coupon_id is not null then
      update public.member_coupons
         set status = 'available',
             used_at = null,
             used_order_id = null,
             updated_at = now()
       where id = v_order.applied_member_coupon_id
         and status = 'used';

      get diagnostics v_iter_count = row_count;
      v_coupon_restored := v_coupon_restored + coalesce(v_iter_count, 0);
    end if;

    v_expired_count := v_expired_count + 1;
  end loop;

  -- 3) 오래된 카드 결제 세션 청소 (24시간) — 세션은 재고를 선점하지 않으므로 위생 목적
  delete from public.pg_checkout_sessions
   where created_at < now() - interval '24 hours';
  get diagnostics v_sessions_purged = row_count;

  return jsonb_build_object(
    'expired_count', v_expired_count,
    'coupons_restored', v_coupon_restored,
    'payment_reminders_sent', v_reminded_count,
    'checkout_sessions_purged', v_sessions_purged,
    'executed_at', now()
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) admin_restore_cancelled_order — 취소 주문 복원
--    p_validate_only = true면 사전 검증만 (어드민 확인 모달에서 사유 미리 보여주기).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_restore_cancelled_order(
  p_order_id      bigint,
  p_validate_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order    record;
  v_item     record;
  v_coupon   record;
  v_blocked  jsonb := '[]'::jsonb;
  v_reserved integer := 0;
  v_coupon_consumed integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  -- (1) 취소된 주문만 대상
  if v_order.status <> 'cancelled' then
    raise exception '취소된 주문만 복원할 수 있습니다. (현재 상태: %)', v_order.status;
  end if;

  -- (2) 결제 이력이 남아 있으면 복원 금지 — 환불 완료건 되살리기 방지.
  --     자동취소·미결제 셀프취소는 이 스탬프가 전부 비어 있다.
  if v_order.paid_at is not null
     or v_order.payment_key is not null
     or v_order.refunded_at is not null
     or coalesce(v_order.refunded_amount, 0) > 0 then
    raise exception '결제·환불 이력이 있는 주문은 복원할 수 없습니다. 새 주문으로 진행해 주세요.';
  end if;

  -- (3) 재고 재선점 가능 여부 검사
  for v_item in
    select oi.id as order_item_id,
           oi.book_id,
           oi.title,
           b.status         as book_status,
           b.serial_number  as serial_number,
           (
             select count(*)
               from public.order_items oi2
               join public.orders o2 on o2.id = oi2.order_id
              where oi2.book_id = oi.book_id
                and o2.id <> p_order_id
                and o2.status not in ('cancelled', 'refunded')
           ) as active_order_count
      from public.order_items oi
      left join public.books b on b.id = oi.book_id
     where oi.order_id = p_order_id
     order by oi.id
  loop
    if v_item.book_id is null or v_item.book_status is null then
      v_blocked := v_blocked || jsonb_build_object(
        'order_item_id', v_item.order_item_id,
        'book_id', v_item.book_id,
        'title', v_item.title,
        'reason', '재고에서 삭제된 책입니다.'
      );
    elsif v_item.active_order_count > 0 then
      v_blocked := v_blocked || jsonb_build_object(
        'order_item_id', v_item.order_item_id,
        'book_id', v_item.book_id,
        'title', v_item.title,
        'serial_number', v_item.serial_number,
        'reason', '다른 주문이 이미 선점한 책입니다.'
      );
    elsif v_item.book_status not in ('on_sale', 'reserved') then
      v_blocked := v_blocked || jsonb_build_object(
        'order_item_id', v_item.order_item_id,
        'book_id', v_item.book_id,
        'title', v_item.title,
        'serial_number', v_item.serial_number,
        'reason', case v_item.book_status
          when 'settled'   then '이미 판매 완료(정산)된 책입니다.'
          when 'discarded' then '폐기 처리된 책입니다.'
          else '판매 불가 상태입니다. (' || v_item.book_status || ')'
        end
      );
    end if;
  end loop;

  -- (4) 쿠폰 재소진 가능 여부 — 할인액은 주문 금액에 이미 반영돼 있으므로 반드시 다시 물려야 한다.
  if v_order.applied_member_coupon_id is not null then
    select * into v_coupon
      from public.member_coupons
     where id = v_order.applied_member_coupon_id
     for update;

    if not found then
      v_blocked := v_blocked || jsonb_build_object(
        'reason', '주문에 적용됐던 쿠폰이 삭제되어 복원할 수 없습니다.'
      );
    elsif v_coupon.status = 'used'
      and v_coupon.used_order_id is distinct from p_order_id then
      v_blocked := v_blocked || jsonb_build_object(
        'reason', '주문에 적용됐던 쿠폰이 그 사이 다른 주문에 사용되었습니다.'
      );
    end if;
  end if;

  if jsonb_array_length(v_blocked) > 0 then
    return jsonb_build_object(
      'success', false,
      'reason', 'blocked',
      'order_id', p_order_id,
      'order_number', v_order.order_number,
      'blocked', v_blocked
    );
  end if;

  if coalesce(p_validate_only, false) then
    return jsonb_build_object(
      'success', true,
      'validate_only', true,
      'order_id', p_order_id,
      'order_number', v_order.order_number,
      'item_count', v_order.item_count,
      'total_amount', v_order.total_amount
    );
  end if;

  -- (5) 주문 복원 — 입금대기로 되돌리고 만료 시계를 지금부터 다시 시작.
  --     리마인더 스탬프도 비워 복원 후 마감 임박 알림이 정상 발송되게 한다.
  update public.orders
     set status                   = 'pending',
         payment_status           = 'pending',
         payment_reminder_sent_at = null,
         restored_at              = now(),
         restored_by              = auth.uid(),
         updated_at               = now()
   where id = p_order_id;

  -- (6) 책 재선점 — is_public=false는 books_enforce_public_storefront_rules가 강제한다.
  update public.books
     set status = 'reserved'
   where id in (select oi.book_id from public.order_items oi where oi.order_id = p_order_id)
     and status = 'on_sale';
  get diagnostics v_reserved = row_count;

  -- (7) 쿠폰 재소진 (expire_unpaid_orders가 available로 되돌려놨던 것을 다시 사용 처리)
  if v_order.applied_member_coupon_id is not null then
    update public.member_coupons
       set status        = 'used',
           used_at       = coalesce(used_at, now()),
           used_order_id = p_order_id,
           updated_at    = now()
     where id = v_order.applied_member_coupon_id
       and (status <> 'used' or used_order_id is distinct from p_order_id);
    get diagnostics v_coupon_consumed = row_count;
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'order_number', v_order.order_number,
    'new_status', 'pending',
    'books_reserved', v_reserved,
    'coupons_reconsumed', v_coupon_consumed,
    'restored_at', now()
  );
end;
$$;

revoke all on function public.admin_restore_cancelled_order(bigint, boolean) from public;
revoke all on function public.admin_restore_cancelled_order(bigint, boolean) from anon;
grant execute on function public.admin_restore_cancelled_order(bigint, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) list_admin_orders — restored_at 노출 (본문 나머지는 현행 그대로)
--    base: 20260824063025(반품 수거 3종) + 20260824070040(환불신청 해소) 반영된 prod 정의
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_admin_orders(p_search text DEFAULT NULL::text, p_statuses text[] DEFAULT NULL::text[], p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- 복원 이력 (2026-08-31 취소 주문 복원 — 어드민 상세에 '복원됨' 표시)
      'restored_at', o.restored_at,
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
$function$
;

commit;

notify pgrst, 'reload schema';
