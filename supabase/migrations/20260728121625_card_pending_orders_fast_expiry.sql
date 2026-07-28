-- 미결제 카드(PG) 주문 빠른 자동취소 — 재고 선점 최소화
--
-- 배경(2026-07-28, 나이스페이 카드결제 라이브 당일): 주문 생성 시 책이 reserved로
--   선점되는데(20260531030000 트리거), 카드 주문의 pending은 "결제창 이탈/실패" 상태라
--   무통장처럼 24시간을 기다릴 이유가 없다. 실패한 결제 시도가 1점물 재고를 최대 하루
--   숨겨버리는 문제.
--
-- 변경 (비파괴 — CREATE OR REPLACE + 신규 함수):
--   1) expire_unpaid_orders(): 만료 조건에 카드(비무통장) 30분 룰 추가.
--      pg_cron 15분 주기(2026051801)라 실제 취소는 생성 후 30~45분 사이.
--      입금 리마인더 단계는 무통장 전용으로 명시(카드는 30분에 만료돼 도달 불가지만 방어).
--   2) cancel_unpaid_order(p_order_number): 미결제(pending+pending) 주문 즉시 취소용
--      service_role 전용 RPC — nicepay-return 서버리스가 "서명 검증된 실패 분기"에서
--      호출해 재고를 즉시 푼다. 쿠폰 자동 복구 포함.
--      (인증실패(authResultCode≠0000) POST는 서명이 없어 위조 가능하므로 서버측 취소
--       금지 — 그 케이스는 fail 페이지가 본인 인증된 cancel_member_order로 처리.)
--
-- 책 릴리스는 trg_release_books_on_order_cancel(상태 전이 트리거)가 담당 — 변경 없음.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) expire_unpaid_orders: 카드 주문 30분 만료 룰
--    (base: 20260716063750 — 리마인더+24h 만료. 시그니처 동일 CREATE OR REPLACE)
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
  v_iter_count      integer;
  v_order           record;
begin
  -- 1) 입금 마감 임박 리마인더 (마감 3시간 전 ~ 마감 전, 1회) — 무통장 전용
  with target as (
    select o.id, o.user_id, o.order_number, o.created_at
    from public.orders o
    where o.status = 'pending'
      and o.payment_status = 'pending'
      and coalesce(o.payment_method, 'bank_transfer') = 'bank_transfer'
      and o.payment_reminder_sent_at is null
      and o.user_id is not null
      and o.created_at < now() - interval '21 hours'
      and o.created_at >= now() - interval '24 hours'
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
        to_char((t.created_at + interval '24 hours') at time zone 'Asia/Seoul', 'MM/DD HH24:MI')
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
  --    · 카드(비무통장): 30분 (결제창 이탈/실패 — 재고 선점 최소화)
  for v_order in
    select id, applied_member_coupon_id
      from public.orders
     where status = 'pending'
       and payment_status = 'pending'
       and (
         created_at < now() - interval '24 hours'
         or (
           coalesce(payment_method, 'bank_transfer') <> 'bank_transfer'
           and created_at < now() - interval '30 minutes'
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

  return jsonb_build_object(
    'expired_count', v_expired_count,
    'coupons_restored', v_coupon_restored,
    'payment_reminders_sent', v_reminded_count,
    'executed_at', now()
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) cancel_unpaid_order: 미결제 주문 즉시 취소 (service_role 전용)
--    nicepay-return이 서명 검증된 실패 분기(승인실패·망취소성공·확정실패+결제취소성공)
--    에서 호출. 결제된 주문(payment_status='paid')은 절대 건드리지 않는다.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.cancel_unpaid_order(p_order_number text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order    record;
  v_restored integer := 0;
begin
  if p_order_number is null or btrim(p_order_number) = '' then
    return jsonb_build_object('success', false, 'reason', 'order_number_required');
  end if;

  select * into v_order
    from public.orders
   where order_number = p_order_number
   for update;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'not_found');
  end if;

  -- 미결제 pending만 취소 가능 — 결제 완료/진행 주문 보호
  if v_order.status <> 'pending' or v_order.payment_status <> 'pending' then
    return jsonb_build_object(
      'success', false,
      'reason', 'not_cancellable',
      'status', v_order.status,
      'payment_status', v_order.payment_status
    );
  end if;

  -- 책 릴리스는 trg_release_books_on_order_cancel 트리거가 수행
  update public.orders
     set status = 'cancelled',
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
    get diagnostics v_restored = row_count;
  end if;

  return jsonb_build_object(
    'success', true,
    'order_id', v_order.id,
    'coupons_restored', v_restored
  );
end;
$$;

revoke all on function public.cancel_unpaid_order(text) from public;
revoke all on function public.cancel_unpaid_order(text) from anon;
revoke all on function public.cancel_unpaid_order(text) from authenticated;
grant execute on function public.cancel_unpaid_order(text) to service_role;

commit;

notify pgrst, 'reload schema';
