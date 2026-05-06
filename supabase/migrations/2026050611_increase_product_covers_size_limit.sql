-- product-covers 버킷의 파일 크기 한도를 5MB → 15MB로 확장.
-- Gemini AI 생성 PNG 일부가 5MB를 초과해서 식스샵 마이그레이션 시 일부 이미지가 업로드 실패함.
-- 15MB로 올리면 모든 식스샵 이미지를 수용 가능 (실제로는 대부분 1~5MB).

update storage.buckets
set file_size_limit = 15728640  -- 15 MB
where id = 'product-covers';
