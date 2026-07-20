-- 슬랙 주문·수거 알림을 Block Kit 카드형으로 업그레이드
--
-- 배경(2026-07-20): 첫 버전이 평문이라 채널에서 알림끼리 구분이 안 됨(사용자 피드백:
--   "볼드체나 구분선이 없으니 헷갈려") → 색상 바 + 헤더 + 2열 필드 카드로 교체.
--
-- 형식 (Slack 공식 문서 확인: docs.slack.dev/reference/block-kit/blocks — header는
--   plain_text 150자, section fields는 mrkdwn 2열 최대 10개; 첨부 color=왼쪽 색상 바):
--   * 주문  = 초록 바(#2eb886) + "📦 새 주문 …" 헤더 + 주문자/결제/수량/금액 필드 + 어드민 링크
--   * 수거  = 파랑 바(#439FE0) + "🚚 새 수거 신청 …" 헤더 + 신청자/연락처/예상권수/박스
--             + 수거 주소 + 어드민 링크
--   * fallback = 푸시 알림 미리보기용 한 줄 요약
--
-- 변경 요약 (비파괴): 트리거 함수 2종 CREATE OR REPLACE (트리거·Vault 시크릿은 그대로).
--   커밋 후 발송·예외 삼킴(주문/수거 생성 보호) 성질은 동일하게 유지.

begin;

-- ── 주문 INSERT → 슬랙 (카드형) ────────────────────────────────────
create or replace function public.notify_slack_new_order()
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

  v_pay := case new.payment_method
    when 'bank_transfer' then '무통장 입금'
    when 'card' then '카드(토스)'
    when 'toss_pay' then '토스페이'
    when 'kakao_pay' then '카카오페이'
    when 'naver_pay' then '네이버페이'
    else coalesce(new.payment_method, '-')
  end;
  v_amount := to_char(coalesce(new.total_amount, 0), 'FM999,999,999,999');

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('attachments', jsonb_build_array(jsonb_build_object(
      'color', '#2eb886',
      'fallback', format('새 주문 %s — %s 님 · %s권 · %s원 · %s',
        new.order_number, coalesce(new.shipping_recipient_name, '이름 미상'),
        coalesce(new.item_count, 0), v_amount, v_pay),
      'blocks', jsonb_build_array(
        jsonb_build_object('type', 'header', 'text', jsonb_build_object(
          'type', 'plain_text', 'text', format('📦 새 주문 %s', new.order_number))),
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
  -- 알림 실패가 주문 생성을 막으면 안 됨
  return new;
end;
$$;

-- ── 수거 신청 INSERT → 슬랙 (카드형) ───────────────────────────────
create or replace function public.notify_slack_new_pickup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_addr text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    return new;
  end if;

  v_addr := btrim(coalesce(new.pickup_address_line1, '') || ' ' || coalesce(new.pickup_address_line2, ''));

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('attachments', jsonb_build_array(jsonb_build_object(
      'color', '#439FE0',
      'fallback', format('새 수거 신청 %s — %s 님 · 예상 %s권 · 박스 %s개',
        new.request_number, coalesce(new.pickup_recipient_name, '이름 미상'),
        coalesce(new.expected_book_count::text, '?'), coalesce(new.box_count::text, '?')),
      'blocks', jsonb_build_array(
        jsonb_build_object('type', 'header', 'text', jsonb_build_object(
          'type', 'plain_text', 'text', format('🚚 새 수거 신청 %s', new.request_number))),
        jsonb_build_object('type', 'section', 'fields', jsonb_build_array(
          jsonb_build_object('type', 'mrkdwn', 'text',
            format(E'*신청자*\n%s 님', coalesce(new.pickup_recipient_name, '이름 미상'))),
          jsonb_build_object('type', 'mrkdwn', 'text',
            format(E'*연락처*\n%s', coalesce(new.pickup_recipient_phone, '-'))),
          jsonb_build_object('type', 'mrkdwn', 'text',
            format(E'*예상 권수*\n%s권', coalesce(new.expected_book_count::text, '?'))),
          jsonb_build_object('type', 'mrkdwn', 'text',
            format(E'*박스*\n%s개', coalesce(new.box_count::text, '?')))
        )),
        jsonb_build_object('type', 'section', 'text', jsonb_build_object(
          'type', 'mrkdwn', 'text',
          format(E'*수거 주소*\n%s', coalesce(nullif(v_addr, ''), '-')))),
        jsonb_build_object('type', 'section', 'text', jsonb_build_object(
          'type', 'mrkdwn', 'text',
          format('<https://admin.subook.kr/admin/pickups?q=%s|어드민에서 수거 확인 →>', new.request_number)))
      )
    )))
  );
  return new;
exception when others then
  -- 알림 실패가 수거 신청 생성을 막으면 안 됨
  return new;
end;
$$;

commit;
