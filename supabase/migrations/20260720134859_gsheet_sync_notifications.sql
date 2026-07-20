-- 구글 스프레드시트 자동 기록 (운영 시트 병행 운영용)
--
-- 배경(2026-07-20): 운영진 일부가 기존 구글시트 관리를 유지하길 원함 → 어드민/DB에서
--   일어나는 일을 시트에 자동 반영해 이중 입력을 없앤다.
--   * 결제 확인(입금확인/PG 승인, pending→paid|preparing) 시
--       → "판매내역(6/8~)" 탭에 품목별 1행 (식스샵 내보내기 열 구조에 헤더명 매핑)
--   * 신규 재고 등록(books INSERT, on_sale) 시
--       → "새 DB(3/30~)" 탭에 일련번호-위치-수거신청자-상품명-판매가-옵션 1행
--
-- 아키텍처: DB 트리거 → pg_net(커밋 후 비동기) → 시트 소유자가 배포한 Apps Script
--   웹앱(doPost)이 탭에 append. 슬랙 알림(20260720130000)과 동일 패턴.
--   * Vault 시크릿 2개: gsheet_sync_webhook_url (Apps Script /exec URL),
--                       gsheet_sync_token (요청 본문 token — 스크립트가 검증)
--   * 둘 중 하나라도 미등록이면 조용히 no-op. 예외는 전부 삼켜 본 흐름을 보호.
--   * 판매 행은 헤더명 키의 객체로 보냄 — 시트 열 순서가 바뀌어도 스크립트가
--     1행 헤더를 읽어 매핑하므로 안전.
--
-- ⚠ 운영 주의: 대량 백필/스크립트로 books를 몇천 건 INSERT하면 시트에도 그대로
--   쏟아진다. 대량 작업 전에는 Vault의 gsheet_sync_webhook_url을 잠시 지웠다가
--   끝나고 재등록할 것.
--
-- 변경 요약 (비파괴): 트리거 함수 2종 + 트리거 2건 (orders UPDATE, books INSERT).

begin;

-- ── 결제 확인 → 판매내역 탭 ────────────────────────────────────────
create or replace function public.notify_gsheet_order_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_token text;
  v_rows jsonb;
  v_pay text;
  v_paid_at text;
  v_buyer record;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token
  from vault.decrypted_secrets where name = 'gsheet_sync_token' limit 1;
  if v_url is null or btrim(v_url) = '' or v_token is null then
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
  v_paid_at := to_char(
    coalesce(new.paid_at, new.pg_approved_at, now()) at time zone 'Asia/Seoul',
    'YYYY-MM-DD HH24:MI:SS'
  );

  select p.name, p.email, p.phone into v_buyer
  from public.member_profiles p
  where p.user_id = new.user_id;

  -- 품목별 1행 — 키는 시트 1행 헤더명과 동일해야 함 (Apps Script가 헤더로 매핑)
  select jsonb_agg(jsonb_build_object(
    '주문 번호', new.order_number,
    '주문 상태', '처리 중',
    '주문 일시', to_char(new.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI:SS'),
    '판매 채널', '수북 웹',
    '상품 이름', oi.title,
    '상품 옵션 정보', coalesce(oi.option_label, ''),
    '단일 정가', b.original_price,
    '단일 판매가', oi.unit_price,
    '구매 수량', oi.quantity,
    '상품 총액', oi.total_price,
    '배송 방식 이름', '일반택배',
    '배송비', coalesce(new.shipping_fee, 0),
    '상품 합계 금액', coalesce(new.subtotal, 0),
    '주문 할인 합계 금액', coalesce(new.discount_amount, 0) + coalesce(new.coupon_discount_amount, 0),
    '주문 금액', coalesce(new.total_amount, 0),
    '결제 상태', '결제 완료',
    '결제 완료 금액', coalesce(new.total_amount, 0),
    '결제1 - 결제 수단', v_pay,
    '결제1 - 결제 금액', coalesce(new.total_amount, 0),
    '결제1 - 결제 일시', v_paid_at,
    '회원 여부', '회원',
    '주문자명', coalesce(v_buyer.name, new.shipping_recipient_name, ''),
    '주문자 이메일', coalesce(v_buyer.email, ''),
    '주문자 핸드폰 번호', coalesce(v_buyer.phone, new.shipping_recipient_phone, ''),
    '수령인 이름', coalesce(new.shipping_recipient_name, ''),
    '수령인 핸드폰 번호', coalesce(new.shipping_recipient_phone, ''),
    '우편번호', coalesce(new.shipping_postal_code, ''),
    '주소', btrim(coalesce(new.shipping_address_line1, '') || ' ' || coalesce(new.shipping_address_line2, '')),
    '상품 위치', concat_ws(' / ', nullif(b.location, ''), b.serial_number::text)
  ) order by oi.id)
  into v_rows
  from public.order_items oi
  left join public.books b on b.id = oi.book_id
  where oi.order_id = new.id;

  if v_rows is null then
    return new;
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('token', v_token, 'kind', 'sale', 'rows', v_rows),
    timeout_milliseconds := 10000
  );
  return new;
exception when others then
  -- 시트 기록 실패가 결제 확인을 막으면 안 됨
  return new;
end;
$$;

drop trigger if exists trg_orders_gsheet_on_paid on public.orders;
create trigger trg_orders_gsheet_on_paid
  after update of status on public.orders
  for each row
  when (old.status = 'pending' and new.status in ('paid', 'preparing'))
  execute function public.notify_gsheet_order_paid();

-- ── 신규 재고 등록 → 새 DB 탭 ──────────────────────────────────────
create or replace function public.notify_gsheet_book_registered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_token text;
  v_seller text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token
  from vault.decrypted_secrets where name = 'gsheet_sync_token' limit 1;
  if v_url is null or btrim(v_url) = '' or v_token is null then
    return new;
  end if;

  select s.seller_name into v_seller
  from public.shipments s
  where s.id = new.shipment_id;

  -- 새 DB 탭 열 순서 그대로: 일련번호-위치-수거신청자-상품명-판매가-옵션
  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('token', v_token, 'kind', 'inventory', 'rows',
      jsonb_build_array(jsonb_build_array(
        new.serial_number,
        coalesce(new.location, ''),
        coalesce(v_seller, ''),
        coalesce(new.title, ''),
        new.price,
        coalesce(new.option, '')
      ))
    ),
    timeout_milliseconds := 10000
  );
  return new;
exception when others then
  -- 시트 기록 실패가 재고 등록을 막으면 안 됨
  return new;
end;
$$;

drop trigger if exists trg_books_gsheet_on_register on public.books;
create trigger trg_books_gsheet_on_register
  after insert on public.books
  for each row
  when (new.status = 'on_sale')
  execute function public.notify_gsheet_book_registered();

commit;
