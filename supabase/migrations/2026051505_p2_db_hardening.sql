-- Phase 6 P2 DB 정리
--
-- 1. books_log_changes_trigger BEFORE → AFTER UPDATE
--    (enforce 트리거가 변경한 최종 값을 로그하기 위해)
-- 2. cart_items.quantity = 1로 정규화 + CHECK 강화
--    (책 1권 1매물 모델 정합)
-- 3. generate_order_number sequence 기반 (MAX+1 race 차단)
-- 4. 인덱스 추가:
--    - orders pending payment_status
--    - orders delivered auto_confirm_at
--    - settlements completed by seller
--    - book_change_logs by admin
-- 5. assert_member_not_blocked()를 add_to_cart에 추가

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) books_log_changes_trigger AFTER UPDATE로 변경
-- ─────────────────────────────────────────────────────────────────────────────
drop trigger if exists books_log_changes_trigger on public.books;
create trigger books_log_changes_trigger
  after update on public.books
  for each row
  execute function public.books_log_changes();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) cart_items quantity 정합 — 책 1권 1매물이므로 quantity = 1 강제
--    기존 quantity > 1 row가 있으면 1로 정규화 후 CHECK 적용
-- ─────────────────────────────────────────────────────────────────────────────
update public.cart_items set quantity = 1 where quantity > 1;

alter table public.cart_items
  drop constraint if exists cart_items_quantity_check;
alter table public.cart_items
  add constraint cart_items_quantity_check check (quantity = 1);

-- add_to_cart RPC도 quantity를 1로 강제
create or replace function public.add_to_cart(
  p_book_id bigint,
  p_product_id bigint default null,
  p_quantity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_book record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  -- 책 1권 1매물: quantity는 무시하고 항상 1로
  select * into v_book from public.books
    where id = p_book_id and status = 'on_sale' and is_public = true;
  if v_book is null then
    raise exception 'Book % is not available', p_book_id;
  end if;

  insert into public.cart_items (user_id, book_id, product_id, quantity)
  values (v_user_id, p_book_id, coalesce(p_product_id, v_book.product_id), 1)
  on conflict (user_id, book_id) do update
    set quantity = 1,
        product_id = coalesce(excluded.product_id, public.cart_items.product_id),
        updated_at = now();

  return jsonb_build_object('success', true, 'book_id', p_book_id);
end;
$$;

grant execute on function public.add_to_cart(bigint, bigint, integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) generate_order_number: sequence 기반 (월별 reset은 안 함 — 단순화)
--    기존 MAX+1 SELECT 경합 차단. unique(order_number)는 유지.
-- ─────────────────────────────────────────────────────────────────────────────
create sequence if not exists public.order_number_seq
  start with 1
  increment by 1
  minvalue 1
  cache 1;

-- 기존 max(order_number)의 seq 부분으로 sequence 끌어올림 (충돌 방지)
do $$
declare
  v_max_seq integer;
begin
  select coalesce(max(
    nullif(substring(order_number from 'ORD-\d{4}-(\d+)$'), '')::integer
  ), 0) into v_max_seq
  from public.orders;

  if v_max_seq > 0 then
    perform setval('public.order_number_seq', v_max_seq, true);
  end if;
end;
$$;

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
  return 'ORD-' || v_year_month || '-' || lpad(v_seq::text, 4, '0');
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 인덱스 추가
-- ─────────────────────────────────────────────────────────────────────────────
create index if not exists idx_orders_pending_created_at
  on public.orders (created_at desc)
  where status = 'pending';

create index if not exists idx_orders_delivered_auto_confirm
  on public.orders (auto_confirm_at)
  where status = 'delivered' and confirmed_at is null;

create index if not exists idx_settlements_seller_completed
  on public.settlements (seller_user_id, completed_at desc)
  where status = 'completed';

create index if not exists idx_book_change_logs_changed_by_at
  on public.book_change_logs (changed_by, changed_at desc);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) assert_member_not_blocked()를 추가 mutation RPC에 삽입
--    confirm_member_purchase: 회원이 직접 구매확정
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare
  v_def text;
begin
  -- confirm_member_purchase 함수가 존재하면 첫 줄에 assert_member_not_blocked 호출 추가는
  -- 정확한 시그니처 매칭이 필요해서 위험. 대신 별도 wrapper로 처리하거나, 함수 자체에서
  -- assert_member_not_blocked 호출이 누락된 곳은 향후 별도 마이그레이션에서 처리.
  -- 여기서는 차단 회원이 confirm/cancel RPC 호출 시 명시 가드를 위해 cancel_member_order에만 적용
  -- (이미 2026051501에서 처리됨).
  null;
end;
$$;

commit;
