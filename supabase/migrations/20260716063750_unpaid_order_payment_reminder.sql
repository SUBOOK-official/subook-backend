-- 무통장 입금 리마인더 (감사 P1)
--
-- 100% 계좌이체 결제인데 주문완료 화면 카운트다운 외에 입금을 상기시킬 채널이 없어
-- "깜빡 → 24시간 경과 → 자동취소"로 새는 주문이 있었다.
--
-- 구현: expire_unpaid_orders()는 pg_cron이 15분마다 호출하는 기존 스케줄러(2026051801)라
-- 별도 cron 없이 이 RPC 안에 리마인더 단계를 추가한다.
--   - 대상: pending+미입금, 마감(생성+24h) 3시간 전 진입, 리마인더 미발송
--   - 채널: 인앱 알림(member_notifications, type='order')만.
--     ⚠ 알림톡은 신규 템플릿이 카카오 검수를 통과해야 해서 보류 — 템플릿 승인 후
--       이 지점에서 notification 발송 경로를 확장할 것.
--   - 멱등: orders.payment_reminder_sent_at으로 1회 보장.
-- 시그니처 동일 — 순수 CREATE OR REPLACE. 기존 만료 루프·쿠폰 복구는 그대로.

alter table public.orders
  add column if not exists payment_reminder_sent_at timestamptz null;

comment on column public.orders.payment_reminder_sent_at is
  '무통장 입금 마감 임박 리마인더(인앱) 발송 시각 — expire_unpaid_orders()가 1회 기록.';

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
  -- 1) 입금 마감 임박 리마인더 (마감 3시간 전 ~ 마감 전, 1회)
  with target as (
    select o.id, o.user_id, o.order_number, o.created_at
    from public.orders o
    where o.status = 'pending'
      and o.payment_status = 'pending'
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

  -- 2) 24시간 경과 미입금 주문 자동 취소 + 쿠폰 복구 (기존 로직 그대로)
  for v_order in
    select id, applied_member_coupon_id
      from public.orders
     where status = 'pending'
       and payment_status = 'pending'
       and created_at < now() - interval '24 hours'
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

notify pgrst, 'reload schema';
