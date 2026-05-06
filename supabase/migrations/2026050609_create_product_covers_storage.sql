-- 식스샵에서 가져올 상품 커버 이미지 저장용 Supabase Storage 버킷.
-- public read (스토어/마이페이지에서 이미지 표시), 어드민만 write.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-covers',
  'product-covers',
  true,
  5242880,                                                    -- 5MB per file
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update
  set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- 정책: 누구나 읽기, 어드민만 쓰기
drop policy if exists "product-covers public read" on storage.objects;
create policy "product-covers public read"
  on storage.objects for select
  using (bucket_id = 'product-covers');

drop policy if exists "product-covers admin write" on storage.objects;
create policy "product-covers admin write"
  on storage.objects for insert
  with check (bucket_id = 'product-covers' and public.is_admin_user());

drop policy if exists "product-covers admin update" on storage.objects;
create policy "product-covers admin update"
  on storage.objects for update
  using (bucket_id = 'product-covers' and public.is_admin_user());

drop policy if exists "product-covers admin delete" on storage.objects;
create policy "product-covers admin delete"
  on storage.objects for delete
  using (bucket_id = 'product-covers' and public.is_admin_user());
