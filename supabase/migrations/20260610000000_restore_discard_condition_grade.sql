-- 2026-06-10 P0 버그 수정: condition_grade CHECK 제약에 'DISCARD' 복원.
--
-- 경위:
--   2026051304_add_discard_grade에서 'DISCARD'를 추가했으나,
--   20260519030001_condition_grade_remove_new이 NEW 제거를 위해 제약을
--   재정의하면서 ('S','A_PLUS','A')로만 좁혀 DISCARD가 누락됨.
--   → admin 검수 화면의 폐기 처리(condition_grade='DISCARD' + status='discarded'
--     동시 UPDATE)가 CHECK 위반으로 전건 실패하는 상태.
--   (프로덕션 제약 실측 확인: 2026-06-10, pg_get_constraintdef로 DISCARD 누락 확인)
--
-- books_status_check('discarded' 포함)와 트리거(books_assert_no_active_order_on_discard),
-- shared-domain status.js의 DISCARD 라벨은 모두 DISCARD 존재를 전제하므로
-- 제약만 원복하면 됨. 데이터 변경 없음(비파괴).

alter table public.books
  drop constraint if exists books_condition_grade_check;

alter table public.books
  add constraint books_condition_grade_check
  check (condition_grade is null or condition_grade in ('S', 'A_PLUS', 'A', 'DISCARD'));
