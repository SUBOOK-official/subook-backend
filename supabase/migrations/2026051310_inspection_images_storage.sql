-- 묶음 10-7: 검수 사진용 Supabase Storage 버킷
-- 운영진이 검수 사진을 직접 업로드 → URL이 inspection_image_urls 배열에 저장.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'inspection-images',
  'inspection-images',
  true,
  10485760,  -- 10MB per file
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "inspection-images public read" on storage.objects;
create policy "inspection-images public read"
  on storage.objects for select
  using (bucket_id = 'inspection-images');

drop policy if exists "inspection-images admin write" on storage.objects;
create policy "inspection-images admin write"
  on storage.objects for insert
  with check (bucket_id = 'inspection-images' and public.is_admin_user());

drop policy if exists "inspection-images admin update" on storage.objects;
create policy "inspection-images admin update"
  on storage.objects for update
  using (bucket_id = 'inspection-images' and public.is_admin_user());

drop policy if exists "inspection-images admin delete" on storage.objects;
create policy "inspection-images admin delete"
  on storage.objects for delete
  using (bucket_id = 'inspection-images' and public.is_admin_user());
