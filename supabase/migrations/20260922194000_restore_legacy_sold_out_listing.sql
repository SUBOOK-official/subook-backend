-- 상품 상태 로그 도입 전 판매 소진도 책의 자동 비노출 이력으로 복원한다.
-- 판매 이후 수동 숨김/공개 변경 흔적이 있으면 유지한다. 책/주문/RLS는 변경하지 않는다.
begin;
lock table public.books, public.products in share row exclusive mode;
with candidates as (
  select p.id
  from public.products p
  cross join lateral (
    select v.book_id,v.old_value,v.new_value,v.changed_at
    from public.book_change_logs v join public.books b on b.id=v.book_id
    where b.product_id=p.id and v.field='is_public'
    order by v.changed_at desc,v.id desc limit 1
  ) last_visibility
  where not p.is_listed and p.status='hidden'
    and not exists(select 1 from public.books b where b.product_id=p.id and b.status='on_sale')
    and exists(select 1 from public.books b where b.product_id=p.id and b.status in ('reserved','settled'))
    and last_visibility.old_value='true' and last_visibility.new_value='false'
    and exists (
      select 1 from public.book_change_logs s
      where s.book_id=last_visibility.book_id and s.field='status'
        and s.old_value='on_sale' and s.new_value in ('reserved','settled')
        and s.changed_at=last_visibility.changed_at
    )
    and not exists (
      select 1 from public.product_status_logs l
      where l.product_id=p.id and l.changed_at>last_visibility.changed_at
    )
)
update public.products p set is_listed=true,updated_at=now()
from candidates c where p.id=c.id;
-- 기존 파생 상태 트리거가 sold_out으로 계산한다. 이후 명시적 숨김은 그대로 유지한다.
commit;
