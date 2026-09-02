-- 후기 불변화 (2026-09-02 사용자 결정): 한 번 작성한 후기는 수정·삭제 불가.
--
-- 수정이 계속 가능하면 신뢰 신호로서의 가치가 떨어지고, 삭제 후 재작성은 사실상 수정과
-- 같아서 둘 다 막는다. 문제가 있는 후기는 어드민이 숨김 처리한다(admin_set_review_hidden).
-- 프런트도 같은 배포에서 수정/삭제 UI를 제거하고 작성된 후기는 읽기 전용으로만 보여준다.

begin;

drop function if exists public.update_review(bigint, integer, text, text[]);
drop function if exists public.delete_review(bigint);

comment on table public.reviews is '통합 구매 후기 — 주문 1건당 1개, 작성 후 수정·삭제 불가(어드민 숨김만), 모든 상품 상세에 공통 노출 (2026-09-02)';

commit;

notify pgrst, 'reload schema';
