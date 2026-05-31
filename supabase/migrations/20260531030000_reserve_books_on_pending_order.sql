-- 유령재고 제거 (정책 A: "주문 시 잠금").
--
-- 문제: 1점물(books)이 pending 주문에 묶여 있어도 status='on_sale'로 남아 storefront에
--       "재고 있음/구매하기"로 노출됨. create_order는 active order(pending 포함)가 있으면
--       차단하므로, 표시(노출)와 실제(주문 불가)가 어긋나 B는 결제 직전에야 막힌다.
--
-- 해결: 책 예약 상태를 "주문 상태에서 파생"시키는 트리거 2개.
--   1) order_items INSERT  → 해당 book on_sale → reserved (주문 생성 즉시 storefront 비노출)
--   2) orders status→cancelled/refunded → reserved book → on_sale 복원
--      (단 같은 책에 다른 active order가 있으면 유지)
--   이로써 create_order / expire_unpaid_orders / cancel_member_order 본문을 재작성하지 않고
--   모든 경로를 일괄 커버. 기존 admin 함수의 명시적 reserve/restore와 멱등 공존(이미 처리된 행 0건).
--
-- 비파괴: CREATE FUNCTION + CREATE TRIGGER 만(데이터 백필 없음). books_status_check는
--         이미 'reserved'를 허용(20260525180000).
-- 참고: 기존(마이그레이션 시점) pending 주문 책은 백필하지 않는다 — 트리거는 신규 주문부터
--       적용되고, 기존 pending은 24h 내 결제(→reserved)되거나 자동취소(→트리거가 정리)되어
--       자연 수렴한다. (출시 직전이라 실거래 pending도 거의 없음 + 데이터 UPDATE 회피)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 주문 생성 시 책 예약 (order_items INSERT 트리거)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.reserve_book_on_order_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.books
  set status = 'reserved'
  where id = new.book_id
    and status = 'on_sale';
  return new;
end;
$$;

drop trigger if exists trg_reserve_book_on_order_item on public.order_items;
create trigger trg_reserve_book_on_order_item
  after insert on public.order_items
  for each row
  execute function public.reserve_book_on_order_item();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 주문 취소/환불 시 책 복원 (orders status UPDATE 트리거)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.release_books_on_order_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('cancelled', 'refunded')
     and old.status not in ('cancelled', 'refunded') then
    -- status='on_sale'과 함께 is_public=true 복원 필수.
    -- books_enforce_public_storefront_rules 트리거가 reserved 전환 시 is_public=false로
    -- 강제했으므로(20260525200000 참고), on_sale로만 되돌리면 storefront에 안 잡힌다.
    update public.books b
    set status = 'on_sale', is_public = true
    where b.id in (
        select oi.book_id from public.order_items oi where oi.order_id = new.id
      )
      and b.status = 'reserved'
      and not exists (
        -- 같은 책에 다른 active(미취소/미환불) order가 있으면 복원하지 않음
        select 1
        from public.order_items oi2
        inner join public.orders o2 on o2.id = oi2.order_id
        where oi2.book_id = b.id
          and o2.id <> new.id
          and o2.status not in ('cancelled', 'refunded')
      );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_release_books_on_order_cancel on public.orders;
create trigger trg_release_books_on_order_cancel
  after update of status on public.orders
  for each row
  execute function public.release_books_on_order_cancel();

commit;
