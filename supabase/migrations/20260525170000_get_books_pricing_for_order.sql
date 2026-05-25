-- PublicOrderPage의 가격 drift 검증용 RPC.
-- books 테이블은 RLS로 admin만 select 가능 — 회원이 직접 .from("books").select()하면
-- 0 row가 돌아와 모든 책이 "unavailable"로 잡혀 주문 페이지가 /cart로 redirect되는 버그가
-- 있었음 (2026-05-25 발견). cart의 get_cart_items처럼 security definer RPC로 우회.
--
-- 회원이 임의의 book_id로 가격을 들춰볼 수 있게 되지만, price/status/is_public 외엔
-- 노출하지 않고 cart/store에서 이미 안 후의 id로만 호출되므로 신규 정보 노출은 없음.

create or replace function public.get_books_pricing_for_order(p_book_ids bigint[])
returns table (
  id bigint,
  price integer,
  status text,
  is_public boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.price, b.status, b.is_public
  from public.books b
  where b.id = any(p_book_ids);
$$;

grant execute on function public.get_books_pricing_for_order(bigint[]) to authenticated;
