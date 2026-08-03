-- get_guest_order items에 product_id 추가 (2026-08-03)
--
-- 배경: 게스트 카드 주문의 purchase 계측(GA4+Meta)이 완료 페이지에서 조회 RPC의
--   items를 재사용하는데, product_id가 없어 Meta 카탈로그 매칭용 content_ids가
--   생략되고 있었다 (다이내믹 광고 retailer_id 매칭 불가). 픽셀 세션 조정 요청 반영.
--
-- 변경: items jsonb에 'product_id' 한 필드 추가. 나머지는 20260803061500과 동일
--   (레이트리밋·2요소 대조·grant 유지).

create or replace function public.get_guest_order(
  p_order_number text,
  p_phone text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ip text;
  v_fail_count integer;
  v_order_number text;
  v_phone_digits text;
  v_order record;
  v_items jsonb;
begin
  -- 호출자 IP (Supabase가 전달하는 요청 헤더) — 실패 시도 레이트리밋 키
  begin
    v_ip := split_part(coalesce(
      current_setting('request.headers', true)::jsonb->>'x-forwarded-for', ''
    ), ',', 1);
  exception when others then
    v_ip := '';
  end;
  if v_ip is null or btrim(v_ip) = '' then
    v_ip := 'noip';
  end if;

  -- 15분 내 실패 20회 초과 → 차단 (순차 주문번호 열거·전화번호 브루트포스 방어)
  select count(*) into v_fail_count
  from public.guest_order_lookup_attempts a
  where a.bucket_key = v_ip
    and a.attempted_at > now() - interval '15 minutes';
  if v_fail_count >= 20 then
    raise exception '조회 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.';
  end if;

  v_order_number := upper(btrim(coalesce(p_order_number, '')));
  v_phone_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');

  select o.* into v_order
  from public.orders o
  where o.user_id is null
    and upper(o.order_number) = v_order_number
    and regexp_replace(coalesce(o.shipping_recipient_phone, ''), '\D', '', 'g') = v_phone_digits
    and length(v_phone_digits) >= 9;

  if not found then
    -- 실패 기록 + 오래된 기록 정리 (테이블 비대화 방지)
    insert into public.guest_order_lookup_attempts (bucket_key) values (v_ip);
    delete from public.guest_order_lookup_attempts
    where attempted_at < now() - interval '1 day';
    return jsonb_build_object('found', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', oi.product_id,
    'title', oi.title,
    'option_label', oi.option_label,
    'condition_grade', oi.condition_grade,
    'cover_image_url', oi.cover_image_url,
    'quantity', oi.quantity,
    'unit_price', oi.unit_price,
    'total_price', oi.total_price,
    'refunded_at', oi.refunded_at,
    'refund_amount', oi.refund_amount
  ) order by oi.id), '[]'::jsonb)
  into v_items
  from public.order_items oi
  where oi.order_id = v_order.id;

  return jsonb_build_object(
    'found', true,
    'order', jsonb_build_object(
      'order_number', v_order.order_number,
      'status', v_order.status,
      'payment_status', v_order.payment_status,
      'payment_method', v_order.payment_method,
      'subtotal', v_order.subtotal,
      'shipping_fee', v_order.shipping_fee,
      'total_amount', v_order.total_amount,
      'refunded_amount', v_order.refunded_amount,
      'item_count', v_order.item_count,
      'created_at', v_order.created_at,
      'paid_at', v_order.paid_at,
      'confirmed_at', v_order.confirmed_at,
      'tracking_number', v_order.tracking_number,
      'tracking_carrier', v_order.tracking_carrier,
      'shipping_recipient_name', v_order.shipping_recipient_name,
      'shipping_recipient_phone', v_order.shipping_recipient_phone,
      'shipping_postal_code', v_order.shipping_postal_code,
      'shipping_address_line1', v_order.shipping_address_line1,
      'shipping_address_line2', v_order.shipping_address_line2,
      'shipping_memo', v_order.shipping_memo,
      'refund_bank_name', v_order.refund_bank_name,
      'refund_account_number', v_order.refund_account_number,
      'refund_account_holder', v_order.refund_account_holder,
      'refund_requested_at', v_order.refund_requested_at,
      'refunded_at', v_order.refunded_at
    ),
    'items', v_items
  );
end;
$function$;

-- grant는 CREATE OR REPLACE로 유지되지만 파일 자체로 완결되게 재기술
revoke all on function public.get_guest_order(text, text) from public;
grant execute on function public.get_guest_order(text, text) to anon;
grant execute on function public.get_guest_order(text, text) to authenticated;

notify pgrst, 'reload schema';
