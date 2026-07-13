-- orders.paid_at — 결제 확인 시각 컬럼 신설 (무통장 입금확인 시각 표시용)
--
-- 배경(2026-07-13): 마이페이지 상세보기 시트의 '결제일시'는 pg_approved_at(PG 전용)만
--   쓸 수 있어 무통장입금 주문은 '주문일시'로 폴백했다. 무통장도 입금확인 시각을
--   보여달라는 요청 — 그런데 admin_confirm_payment는 updated_at만 갱신하고(이후 상태변경마다
--   덮어써짐) 입금확인 시각이 어디에도 남지 않았다.
--
-- 설계: 개별 함수 3곳(admin_confirm_payment / confirm_pg_payment / 레거시
--   admin_update_order_status의 pending→paid)을 각각 수정하는 대신, payment_status가
--   'paid'로 전이되는 순간을 BEFORE 트리거로 잡아 한 곳에서 스탬프한다.
--   → 일괄 입금확인(admin_bulk_confirm_payment는 admin_confirm_payment를 loop 호출)과
--     향후 추가될 결제 확정 경로까지 자동 커버.
--
-- 백필 없음: 과거 PG 주문은 프론트가 paid_at ?? pg_approved_at 폴백 체인으로 처리하고,
--   과거 무통장 주문은 정확한 시각이 어디에도 없으므로(허위 시각 방지) '주문일시' 폴백 유지.
--
-- 비파괴: ADD COLUMN IF NOT EXISTS + 신규 트리거 + CREATE OR REPLACE FUNCTION.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists paid_at timestamptz;

comment on column public.orders.paid_at is
  '결제 확인 시각(무통장 입금확인·PG 승인 공통). trg_orders_stamp_paid_at 트리거가 payment_status→paid 전이 시 자동 기록. 20260713 이전 주문은 NULL(PG는 pg_approved_at 참조)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 트리거: payment_status가 paid로 "전이"되는 순간 1회만 스탬프
--    - 환불(paid→refunded)이나 그 외 갱신에는 관여하지 않음 (paid_at은 이력으로 보존)
--    - 이미 paid_at이 있으면 덮어쓰지 않음(최초 결제 확인 시각 유지)
--    - 같은 UPDATE 안에서 paid_at을 명시적으로 세팅하면 그 값을 존중
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.stamp_order_paid_at()
returns trigger
language plpgsql
as $$
begin
  if new.payment_status = 'paid'
     and new.paid_at is null
     and (tg_op = 'INSERT' or old.payment_status is distinct from 'paid') then
    new.paid_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_stamp_paid_at on public.orders;
create trigger trg_orders_stamp_paid_at
  before insert or update of payment_status, paid_at
  on public.orders
  for each row
  execute function public.stamp_order_paid_at();

comment on function public.stamp_order_paid_at() is
  'orders.payment_status가 paid로 전이될 때 paid_at 자동 스탬프 — 입금확인/PG승인/레거시 전이 공통 커버 (2026-07-13)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) get_my_orders: paid_at 노출 (base: 20260713033718 — 'paid_at' 한 줄 추가)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_my_orders(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      -- 입금 안내(입금자명 = 성함 + 주문번호 4자리) 재노출에 필요
      'shipping_recipient_name', o.shipping_recipient_name,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      'discount_amount', o.discount_amount,
      -- 상세보기 시트: 쿠폰할인 금액 + 결제 확인 시각 (2026-07-13)
      'coupon_discount_amount', o.coupon_discount_amount,
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'product_id', oi.product_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          -- ⚠ 식스샵 import 책은 oi.cover_image_url이 NULL — products fallback
          'cover_image_url', coalesce(
            nullif(btrim(oi.cover_image_url), ''),
            nullif(btrim(p.cover_image_url), '')
          ),
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price
        ) order by oi.id)
        from public.order_items oi
        left join public.products p on p.id = oi.product_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    where o.user_id = v_user_id
    order by o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

commit;
