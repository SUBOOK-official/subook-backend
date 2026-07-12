-- 상품 AI 요약 (2026-07-12)
--
-- 상세 페이지 "AI 요약" 탭의 실데이터. 실시간 생성이 아니라 배치 사전 생성
-- (tools/generate-ai-summaries.mjs — Gemini + 구글 검색 그라운딩) 후 저장하는 구조:
--   - 환각 대응: 검색으로 확인된 내용만 서술하도록 프롬프트 제한 + 어드민 검수/수정(후속)
--   - 상세 페이지는 products_select_public RLS로 anon이 바로 읽음 (RPC 불필요)
-- ai_summary_sources: 그라운딩 출처 URL 목록(검수용). 프론트 노출은 선택.

alter table public.products
  add column if not exists ai_summary text null,
  add column if not exists ai_summary_sources jsonb null,
  add column if not exists ai_summary_generated_at timestamptz null;

comment on column public.products.ai_summary is
  'AI 생성 교재 소개 (Gemini+검색 그라운딩 배치 생성, 어드민 수정 가능). null이면 상세 페이지 섹션 미노출.';
