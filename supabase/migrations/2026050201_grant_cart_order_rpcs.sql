-- 장바구니/주문 RPC 들에 authenticated 역할 EXECUTE 권한 명시
-- (이전 마이그레이션 2026041001 에서 grant 가 누락되어 있어 환경에 따라
--  '장바구니 담기에 실패했습니다.' 가 발생할 수 있어 보강)

grant execute on function public.add_to_cart(bigint, bigint, integer)
  to authenticated;

grant execute on function public.get_cart_items()
  to authenticated;

grant execute on function public.create_order(bigint[], integer[], text, text, text, text, text, text, text)
  to authenticated;
