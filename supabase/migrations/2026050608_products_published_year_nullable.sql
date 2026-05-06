-- 식스샵 데이터에 연도가 없는 책들이 일부 존재 (워드마스터 등 시리즈 책).
-- books는 이미 nullable이라 products도 동일하게 변경.
-- 기존 NOT NULL 제약만 제거 (CHECK 범위는 유지: 값 있으면 2000~2100).

alter table public.products
  alter column published_year drop not null;

alter table public.products drop constraint if exists products_published_year_check;
alter table public.products add constraint products_published_year_check
  check (published_year is null or (published_year >= 2000 and published_year <= 2100));
