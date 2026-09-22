-- 변경 이력이 없는 이전 상품은 현재 전량 판매완료 상태로 품절을 복원한다.
-- 2026-05-06 식스샵 이관 시기에 생성되고 책 로그 도입(2026-05-13)보다 오래된 상품 대상.
-- 과거 로그 부재는 수동 숨김의 증거가 아니다. 빈 상품/폐기/미판매 재고는 포함하지 않는다.
-- RLS/권한/책/주문은 변경하지 않는다. 기존 상태 트리거가 품절 계산과 변경 로그를 남긴다.
-- 롤백: 적용 때 기록된 hidden→sold_out 대상 중 후속 운영 변경이 없는 것만 별도 migration으로 복원.
begin;
lock table public.books, public.products in share row exclusive mode;
with candidates as (
  select p.id
  from public.products p
  where p.status='hidden' and not p.is_listed
    and p.created_at < timestamptz '2026-05-13 00:00:00+00'
    -- 공개 설정 분리 도입 이후에 운영자가 수정한 상품을 덮어쓰지 않는다.
    and p.updated_at < timestamptz '2026-09-22 18:03:18+00'
    and exists(select 1 from public.books b where b.product_id=p.id)
    and not exists(select 1 from public.books b where b.product_id=p.id and b.status is distinct from 'settled')
    and not exists(select 1 from public.product_status_logs l where l.product_id=p.id)
    and not exists (
      select 1 from public.book_change_logs l join public.books b on b.id=l.book_id
      where b.product_id=p.id and l.field in ('status','is_public')
    )
)
update public.products p set is_listed=true,updated_at=now()
from candidates c where p.id=c.id;
commit;
