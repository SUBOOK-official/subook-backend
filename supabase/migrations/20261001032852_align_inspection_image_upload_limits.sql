-- 등록·상품 수정 화면은 15MiB/GIF를 허용하지만 상세사진 버킷은 10MiB/GIF 불가였다.
-- 원본 화질을 보존하면서 product-covers와 같은 업로드 제한을 적용한다.
-- 버킷 설정만 변경하며 기존 파일·상품 데이터, public 여부, storage.objects RLS는 유지한다.
-- https://supabase.com/docs/guides/storage/uploads/file-limits
update storage.buckets
set file_size_limit = 15728640,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
where id = 'inspection-images';

-- 롤백: file_size_limit=10485760, allowed_mime_types=array['image/jpeg','image/png','image/webp'].
-- 롤백해도 이미 업로드된 파일은 삭제하지 않는다.
