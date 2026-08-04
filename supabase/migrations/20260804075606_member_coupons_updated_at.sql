-- member_coupons.updated_at 컬럼 추가 — RPC 정의와 실스키마 정합화 (긴급)
--
-- 2026-08-04 ORD-2608-0077(쿠폰 사용 주문 전액 환불)에서 발견:
-- admin_refund_order / admin_refund_order_items의 쿠폰 복구 블록이
-- member_coupons.updated_at = now()를 갱신하지만, 테이블 생성(2026050602)에는
-- updated_at 컬럼이 없어 `column "updated_at" of relation "member_coupons" does
-- not exist`로 환불 트랜잭션 전체가 롤백됐다 (PG 취소 성공 후 DB 확정 실패).
--
-- 같은 패턴이 취소 계열에도 있어 이 컬럼 추가로 함께 해소된다:
--   · 20260728121625 미결제 카드 주문 만료 (15분 pg_cron 경유)
--   · 20260803041815 cancel_member_order / cancel_unpaid_order 재정의판
--   → 쿠폰 사용 주문의 취소·자동만료도 2026-08-03부터 같은 에러로 실패 가능성.
--     (컬럼 추가만으로 별도 재실행 없이 다음 크론/호출부터 정상 동작)
--
-- 결제 확정(쿠폰 used 전이) 경로는 updated_at을 쓰지 않아 영향 없었다.
-- RLS: 컬럼 추가뿐이라 정책 변경 없음 — 기존 member_coupons RLS 그대로 적용.

alter table public.member_coupons
  add column if not exists updated_at timestamptz not null default now();

comment on column public.member_coupons.updated_at is
  '마지막 변경 시각 — 환불/취소 시 쿠폰 복구 RPC들이 명시 갱신 (2026-08-04 추가)';
