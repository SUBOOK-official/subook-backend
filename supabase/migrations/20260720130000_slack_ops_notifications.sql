-- 신규 주문·수거 신청 팀 슬랙 알림 (즉각 대응용)
--
-- 배경(2026-07-20): 주문/수거 신청이 들어와도 어드민에 들어가야만 알 수 있어
--   대응이 늦어짐 → INSERT 시점에 팀 슬랙 채널로 즉시 알림을 쏜다.
--
-- 아키텍처: DB 트리거 → pg_net(net.http_post, 비동기) → Slack Incoming Webhook.
--   * 서버리스 경유 없이 DB에서 직접 발송 — 앱이 어디서 주문을 만들든(공웹/RPC) 빠짐없이 잡힘.
--   * pg_net은 트랜잭션 "커밋 후"에만 요청을 발사 → 롤백된 주문은 알림이 안 감.
--     (참고: https://supabase.com/docs/guides/database/extensions/pg_net)
--   * 웹훅 URL은 Vault 시크릿 `slack_ops_webhook_url`로 보관 — 코드/깃에 노출 금지.
--     등록:   select vault.create_secret('https://hooks.slack.com/services/…',
--                                        'slack_ops_webhook_url', '주문/수거 슬랙 알림');
--     미등록 상태면 트리거는 조용히 no-op (알림만 안 감, 주문/수거는 정상 동작).
--   * 알림 실패(네트워크·설정 오류 등)는 예외를 삼켜 주문/수거 생성을 절대 막지 않는다.
--
-- 변경 요약 (비파괴): pg_net 활성화 + 트리거 함수 2종 + AFTER INSERT 트리거 2건.

begin;

create extension if not exists pg_net;

-- ── 주문 INSERT → 슬랙 ─────────────────────────────────────────────
create or replace function public.notify_slack_new_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_pay text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    return new;
  end if;

  v_pay := case new.payment_method
    when 'bank_transfer' then '무통장 입금'
    when 'card' then '카드(토스)'
    when 'toss_pay' then '토스페이'
    when 'kakao_pay' then '카카오페이'
    when 'naver_pay' then '네이버페이'
    else coalesce(new.payment_method, '-')
  end;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('text', format(
      E':package: 새 주문 %s\n%s 님 · %s권 · %s원 · %s\nhttps://admin.subook.kr/admin/orders?q=%s',
      new.order_number,
      coalesce(new.shipping_recipient_name, '이름 미상'),
      coalesce(new.item_count, 0),
      to_char(coalesce(new.total_amount, 0), 'FM999,999,999,999'),
      v_pay,
      new.order_number
    ))
  );
  return new;
exception when others then
  -- 알림 실패가 주문 생성을 막으면 안 됨
  return new;
end;
$$;

drop trigger if exists trg_orders_notify_slack on public.orders;
create trigger trg_orders_notify_slack
  after insert on public.orders
  for each row execute function public.notify_slack_new_order();

-- ── 수거 신청 INSERT → 슬랙 ────────────────────────────────────────
create or replace function public.notify_slack_new_pickup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    return new;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('text', format(
      E':truck: 새 수거 신청 %s\n%s 님 (%s) · 예상 %s권 · 박스 %s개\n%s %s\nhttps://admin.subook.kr/admin/pickups?q=%s',
      new.request_number,
      coalesce(new.pickup_recipient_name, '이름 미상'),
      coalesce(new.pickup_recipient_phone, '-'),
      coalesce(new.expected_book_count::text, '?'),
      coalesce(new.box_count::text, '?'),
      coalesce(new.pickup_address_line1, ''),
      coalesce(new.pickup_address_line2, ''),
      new.request_number
    ))
  );
  return new;
exception when others then
  -- 알림 실패가 수거 신청 생성을 막으면 안 됨
  return new;
end;
$$;

drop trigger if exists trg_pickup_requests_notify_slack on public.pickup_requests;
create trigger trg_pickup_requests_notify_slack
  after insert on public.pickup_requests
  for each row execute function public.notify_slack_new_pickup();

commit;
