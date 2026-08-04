-- 구글시트 동기화 트리거 pg_net 타임아웃 상향 (10s → 25s)
--
-- 배경(2026-07-20 실검증): Apps Script가 무거운 시트에 append할 때 응답이 10초를 넘겨
--   pg_net이 타임아웃났다(status_code null). Apps Script는 배치 쓰기로 개선했지만,
--   시트가 계속 커지는 것을 감안해 트리거 쪽 타임아웃도 여유있게 25초로 올린다.
--   (pg_net 타임아웃은 응답 대기 한도일 뿐 — 초과해도 Apps Script 실행/기록 자체는 진행됨)
--
-- 변경: 20260720134859 정의에서 timeout_milliseconds만 25000으로 (그 외 로직 동일).

begin;

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
    timeout_milliseconds := 25000
  );
  return new;
exception when others then
  return new;
end;
$$;

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
    timeout_milliseconds := 25000
  );
  return new;
exception when others then
  return new;
end;
$$;

commit;
