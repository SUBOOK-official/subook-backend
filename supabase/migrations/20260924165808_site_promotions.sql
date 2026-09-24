-- 홈 배너/팝업 CMS. 기존 콘텐츠는 보존하고 요청받은 교재 구매 배너만 비노출로 이관.
-- 공식 권한 기준: https://supabase.com/docs/guides/database/postgres/row-level-security
create table public.site_promotions (
  id uuid primary key default gen_random_uuid(),
  placement text not null check (placement in ('home_hero', 'home_popup')),
  title text not null check (length(btrim(title)) between 1 and 100),
  image_url text not null check (image_url ~ '^(/[^/\\]|https://[^[:space:]]+)'),
  mobile_image_url text check (mobile_image_url ~ '^(/[^/\\]|https://[^[:space:]]+)'),
  alt_text text not null check (length(btrim(alt_text)) between 1 and 1000),
  link_url text check (link_url = '/' or link_url ~ '^(/[^/\\]|https://[^[:space:]]+)'),
  is_enabled boolean not null default false,
  sort_order integer not null default 100 check (sort_order between 0 and 9999),
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint site_promotions_schedule check (starts_at is null or ends_at is null or ends_at > starts_at)
);
alter table public.site_promotions enable row level security;
revoke all on public.site_promotions from anon, authenticated;
grant select on public.site_promotions to anon;
grant select, insert, update, delete on public.site_promotions to authenticated;
grant all on public.site_promotions to service_role;
create policy site_promotions_published_read on public.site_promotions
  for select to anon, authenticated using (
    is_enabled and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())
  );
create policy site_promotions_admin_all on public.site_promotions
  for all to authenticated using ((select public.is_admin_user()))
  with check ((select public.is_admin_user()));

create function public.touch_site_promotion() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;
create trigger site_promotions_updated before update on public.site_promotions
  for each row execute function public.touch_site_promotion();
create index site_promotions_display on public.site_promotions (placement, sort_order, id) where is_enabled;

-- 전용 공개 이미지 버킷. SVG/HTML 업로드 금지, 새 UUID 경로만 사용해 CDN 캐시 충돌 방지.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site-promotions', 'site-promotions', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);
create policy site_promotions_images_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'site-promotions');
create policy site_promotions_images_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'site-promotions' and (select public.is_admin_user()));
create policy site_promotions_images_update on storage.objects
  for update to authenticated using (bucket_id = 'site-promotions' and (select public.is_admin_user()))
  with check (bucket_id = 'site-promotions' and (select public.is_admin_user()));

insert into public.site_promotions
  (id, placement, title, image_url, mobile_image_url, alt_text, link_url, is_enabled, sort_order, ends_at)
values
  ('7dc09884-a380-4062-8099-0438aab03101', 'home_hero', '전일학원 × 수북 콜라보', '/banners/hero-banner-4-desktop.webp', '/banners/hero-banner-4-mobile.webp', '전일학원 × 수북 콜라보 한정판 교재 - 전일학원 이벤트 바로가기', '/event/jeon-il', true, 10, null),
  ('7dc09884-a380-4062-8099-0438aab03102', 'home_hero', '대치동 현강 희귀 모의고사 (내림)', '/banners/hero-banner-1-desktop.webp', '/banners/hero-banner-1-mobile.webp', '대치동 현강 희귀 모의고사부터 S급 기출·내신 교재까지', '/#products', false, 20, null),
  ('7dc09884-a380-4062-8099-0438aab03103', 'home_hero', '교재 판매 신청', '/banners/hero-banner-2-desktop.webp', '/banners/hero-banner-2-mobile.webp', '집에 쌓인 교재를 합리적인 정산금으로 - 판매 신청하기', '/sell', true, 30, null),
  ('7dc09884-a380-4062-8099-0438aab03104', 'home_hero', '수북 자주 묻는 질문', '/banners/hero-banner-3-desktop.webp', '/banners/hero-banner-3-mobile.webp', '수북, 정말 믿고 사도 되는걸까요? 자주 묻는 질문 FAQ 바로가기', '/faq', true, 40, null),
  ('7dc09884-a380-4062-8099-0438aab03105', 'home_popup', '2026 추석 쿠폰 및 배송 안내', '/banners/chuseok-2026.webp', null, '추석 이후 수능까지, 수북이 함께합니다. 전 제품 6,000원 할인 쿠폰 코드: 2026수북추석. 마이페이지 쿠폰 보유내역에서 등록 가능하며 선착순 소진 시 조기 종료됩니다. 추석 배송: 9월 23일 택배 마감, 9월 24~27일 연휴, 9월 28일부터 순차 출고.', '/mypage#coupons', true, 10, '2026-09-29T00:00:00+09:00');

-- 롤백: 앱 이전 버전을 먼저 배포하고 이 신규 테이블/정책만 별도 검토 후 제거한다.
-- storage 파일 삭제는 SQL 대신 Storage API로 처리한다. 기존 업무 테이블 변경 없음.
