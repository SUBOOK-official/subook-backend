-- 2028 수능 PDF 자료실. 기존 업무 테이블/정책에는 영향 없음.
-- https://supabase.com/docs/guides/storage/uploads/resumable-uploads
create table public.admin_study_materials (
  id uuid primary key,
  exam_year integer not null default 2028 check (exam_year = 2028),
  subject text not null check (subject in ('국어','수학','영어','한국사','통합사회','통합과학','기타')),
  subject_detail text not null default '' check (length(subject_detail) <= 80),
  title text not null check (length(btrim(title)) between 1 and 300),
  file_name text not null check (length(file_name) between 5 and 350 and lower(right(file_name,4)) = '.pdf'),
  storage_path text not null unique check (storage_path = '2028/' || id::text || '.pdf'),
  size_bytes bigint not null check (size_bytes between 5 and 1073741824),
  uploaded_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index admin_study_materials_category_idx on public.admin_study_materials(subject, subject_detail, created_at desc);
alter table public.admin_study_materials enable row level security;
revoke all on public.admin_study_materials from anon, authenticated;
grant select on public.admin_study_materials to authenticated;
grant all on public.admin_study_materials to service_role;
create policy admin_study_materials_read on public.admin_study_materials
  for select to authenticated using ((select public.is_admin_user()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('admin-study-materials','admin-study-materials',false,1073741824,array['application/pdf']);
create policy admin_study_materials_files_read on storage.objects
  for select to authenticated using (bucket_id = 'admin-study-materials' and (select public.is_admin_user()));
create policy admin_study_materials_files_insert on storage.objects
  for insert to authenticated with check (
    bucket_id = 'admin-study-materials' and (select public.is_admin_user())
    and name ~ '^2028/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
  );

-- 업로드 완료된 실제 객체와 크기/MIME을 검증한 뒤에만 목록에 등록한다.
-- 동일 ID 재시도는 기존 행을 반환하여 응답 유실 시 중복 등록을 방지한다.
create function public.admin_register_study_material(
  p_id uuid, p_subject text, p_subject_detail text, p_title text, p_file_name text, p_size_bytes bigint
) returns public.admin_study_materials
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_row public.admin_study_materials;
  v_path text := '2028/' || p_id::text || '.pdf';
begin
  if not coalesce(public.is_admin_user(), false) then
    raise exception '관리자 권한이 필요합니다.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from storage.objects where bucket_id='admin-study-materials' and name=v_path
      and (metadata->>'size')::bigint=p_size_bytes and metadata->>'mimetype'='application/pdf'
  ) then
    raise exception 'PDF 업로드가 완료되지 않았습니다. 다시 시도해 주세요.' using errcode = '22023';
  end if;
  insert into public.admin_study_materials(id,subject,subject_detail,title,file_name,storage_path,size_bytes)
  values(p_id,btrim(p_subject),btrim(coalesce(p_subject_detail,'')),btrim(p_title),p_file_name,v_path,p_size_bytes)
  on conflict(id) do nothing;
  select * into v_row from public.admin_study_materials where id=p_id;
  if v_row.subject is distinct from btrim(p_subject) or v_row.subject_detail is distinct from btrim(coalesce(p_subject_detail,''))
    or v_row.file_name is distinct from p_file_name or v_row.size_bytes is distinct from p_size_bytes
    or v_row.title is distinct from btrim(p_title) then
    raise exception '이미 등록된 자료의 정보와 일치하지 않습니다.' using errcode = '22023';
  end if;
  return v_row;
end;
$$;
revoke all on function public.admin_register_study_material(uuid,text,text,text,text,bigint) from public, anon;
grant execute on function public.admin_register_study_material(uuid,text,text,text,text,bigint) to authenticated;

-- 롤백: 새 메뉴를 제거하고 자료/객체를 보존한 상태로 이 테이블·함수의 접근 권한을 회수한다.
-- 자료 폐기 시 별도 확인 후 Storage API로 객체를 삭제한다(SQL로 storage.objects 삭제 금지).
