-- generate_order_number: lpad 잘림(주문번호 충돌) 선제 수리
--
-- 문제: lpad(v_seq::text, 4, '0')는 seq가 5자리(10000+)가 되는 순간
--   오른쪽을 잘라 4자리로 만든다 (postgres lpad 규격: 길이 초과 시 truncate,
--   lpad('10000', 4, '0') = '1000'). 서로 다른 seq가 같은 주문번호로 잘려
--   orders.order_number unique 충돌 → 주문 생성 자체가 실패하게 된다.
--   2026-08-03부터 카드 결제 세션(pg_checkout_sessions)도 이 함수로 채번을
--   시작해 시퀀스 소비 속도가 빨라졌으므로 미리 고쳐 둔다.
--
-- 수리: 4자리까지는 기존과 동일하게 0 패딩(ORD-YYMM-0001 ~ ORD-YYMM-9999),
--   5자리 이상은 자르지 않고 그대로 이어 붙인다(ORD-YYMM-10000, ...).
--   기존 번호 형식은 바뀌지 않는다.

begin;

create or replace function public.generate_order_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year_month text;
  v_seq bigint;
begin
  v_year_month := to_char(now(), 'YYMM');
  v_seq := nextval('public.order_number_seq');
  -- greatest(): seq가 4자리 이하면 4자리로 0 패딩, 5자리 이상이면 제 길이 그대로 (잘림 방지)
  return 'ORD-' || v_year_month || '-' || lpad(v_seq::text, greatest(length(v_seq::text), 4), '0');
end;
$$;

commit;
