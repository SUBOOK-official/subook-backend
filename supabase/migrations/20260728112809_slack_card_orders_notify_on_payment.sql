-- 카드(PG) 주문 슬랙 알림을 '결제 완료 시점'으로 이동
--
-- 배경(2026-07-28, 나이스페이 카드결제 라이브 첫날 실결제 검증에서 발견):
--   주문 슬랙 알림이 orders INSERT 트리거라서, 카드 주문은 결제창을 열기도 전에
--   (pending 생성 시점에) "새 주문" 핑이 감 → 결제창 이탈/실패 건도 전부 알림.
--   무통장은 INSERT 시점 = "입금대기 접수"라 의미가 맞지만 카드는 아님.
--
-- 변경 (비파괴 — 함수 CREATE OR REPLACE + 트리거 재생성):
--   1) INSERT 알림(trg_orders_notify_slack)에 WHEN 절 추가 → 무통장(bank_transfer,
--      NULL 포함)만 발사. 기존 notify_slack_new_order() 함수 본문은 그대로 둔다.
--   2) 결제 확정 알림 신설: pending→preparing 전이 && 무통장이 아닌 주문
--      (= confirm_pg_payment 경유 카드/PG 결제)에서 "카드 결제 완료" 카드 발사.
--
-- 유지되는 성질(재정의 시에도 반드시 유지):
--   * pg_net(net.http_post) = 트랜잭션 커밋 후 발송 — 롤백된 전이는 알림 안 감
--   * 예외 삼킴 — 알림 실패가 주문/결제 전이를 절대 막지 않음
--   * 웹훅 URL은 Vault 시크릿 slack_ops_webhook_url (미등록이면 조용히 no-op)

begin;

-- ── 1) 주문 INSERT 알림은 무통장만 ──────────────────────────────────
drop trigger if exists trg_orders_notify_slack on public.orders;
create trigger trg_orders_notify_slack
  after insert on public.orders
  for each row
  when (coalesce(new.payment_method, 'bank_transfer') = 'bank_transfer')
  execute function public.notify_slack_new_order();

-- ── 2) 카드(PG) 결제 확정 → 슬랙 (카드형) ───────────────────────────
create or replace function public.notify_slack_order_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_pay text;
  v_amount text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    return new;
  end if;

  v_pay := case coalesce(new.pg_provider, '')
    when 'nicepay' then '카드 (나이스페이)'
    when 'toss' then '카드 (토스)'
    else case new.payment_method
      when 'card' then '카드'
      when 'toss_pay' then '토스페이'
      when 'kakao_pay' then '카카오페이'
      when 'naver_pay' then '네이버페이'
      else coalesce(new.payment_method, '-')
    end
  end;
  v_amount := to_char(coalesce(new.total_amount, 0), 'FM999,999,999,999');

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('attachments', jsonb_build_array(jsonb_build_object(
      'color', '#2eb886',
      'fallback', format('카드 결제 완료 %s — %s 님 · %s권 · %s원 · %s',
        new.order_number, coalesce(new.shipping_recipient_name, '이름 미상'),
        coalesce(new.item_count, 0), v_amount, v_pay),
      'blocks', jsonb_build_array(
        jsonb_build_object('type', 'header', 'text', jsonb_build_object(
          'type', 'plain_text', 'text', format('💳 카드 결제 완료 %s', new.order_number))),
        jsonb_build_object('type', 'section', 'fields', jsonb_build_array(
          jsonb_build_object('type', 'mrkdwn', 'text',
            format(E'*주문자*\n%s 님', coalesce(new.shipping_recipient_name, '이름 미상'))),
          jsonb_build_object('type', 'mrkdwn', 'text', format(E'*결제 수단*\n%s', v_pay)),
          jsonb_build_object('type', 'mrkdwn', 'text',
            format(E'*수량*\n%s권', coalesce(new.item_count, 0))),
          jsonb_build_object('type', 'mrkdwn', 'text', format(E'*결제 금액*\n%s원', v_amount))
        )),
        jsonb_build_object('type', 'section', 'text', jsonb_build_object(
          'type', 'mrkdwn', 'text',
          format('<https://admin.subook.kr/admin/orders?q=%s|어드민에서 주문 확인 →>', new.order_number)))
      )
    )))
  );
  return new;
exception when others then
  -- 알림 실패가 결제 확정 전이를 막으면 안 됨
  return new;
end;
$$;

drop trigger if exists trg_orders_notify_slack_paid on public.orders;
create trigger trg_orders_notify_slack_paid
  after update on public.orders
  for each row
  when (
    old.status = 'pending'
    and new.status = 'preparing'
    and coalesce(new.payment_method, 'bank_transfer') <> 'bank_transfer'
  )
  execute function public.notify_slack_order_paid();

commit;
