-- DISCARD 등급/discarded 상태 전환 가드
-- 활성 주문(order_items에 cancelled/refunded 아닌 order)이 있는 책의
-- condition_grade를 DISCARD로 또는 status를 'discarded'로 변경하지 못하게 차단.
-- 운영자가 실수로 폐기 표시하면 구매자가 이미 주문한 책이 사라지는 사고 방지.

begin;

create or replace function public.books_assert_no_active_order_on_discard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active_count integer;
  v_is_discard_transition boolean;
begin
  v_is_discard_transition :=
    (coalesce(new.condition_grade, '') = 'DISCARD' and coalesce(old.condition_grade, '') <> 'DISCARD')
    or (coalesce(new.status, '') = 'discarded' and coalesce(old.status, '') <> 'discarded');

  if not v_is_discard_transition then
    return new;
  end if;

  select count(*) into v_active_count
  from public.order_items oi
  inner join public.orders o on o.id = oi.order_id
  where oi.book_id = new.id
    and o.status not in ('cancelled', 'refunded');

  if v_active_count > 0 then
    raise exception '활성 주문(% 건)이 있는 책은 폐기 처리할 수 없습니다. 환불 처리 후 다시 시도해 주세요.', v_active_count;
  end if;

  return new;
end;
$$;

drop trigger if exists books_discard_active_order_guard on public.books;
create trigger books_discard_active_order_guard
  before update of condition_grade, status on public.books
  for each row
  execute function public.books_assert_no_active_order_on_discard();

commit;
