-- 식스샵 데이터 마이그레이션 후속:
--   brand에 '기타' 추가 (식스샵의 미분류 카테고리)
--   book_type에 '논술' 추가
--
-- 기존 enum은 유지하고 추가만. Non-destructive.

alter table public.books drop constraint if exists books_brand_check;
alter table public.books add constraint books_brand_check
  check (brand is null or brand in (
    '시대인재', '강남대성', '대성마이맥', '이투스', 'EBS',
    '메가스터디', '이감', '상상국어평가연구소',
    '기타'
  ));

alter table public.books drop constraint if exists books_book_type_check;
alter table public.books add constraint books_book_type_check
  check (book_type is null or book_type in (
    '기출', '모의고사', 'N제', 'EBS', '주간지', '내신',
    '개념', '워크북',
    '논술'
  ));

alter table public.products drop constraint if exists products_brand_check;
alter table public.products add constraint products_brand_check
  check (
    nullif(btrim(coalesce(brand, '')), '') is not null
    and brand in (
      '시대인재', '강남대성', '대성마이맥', '이투스', 'EBS',
      '메가스터디', '이감', '상상국어평가연구소',
      '기타'
    )
  );

alter table public.products drop constraint if exists products_book_type_check;
alter table public.products add constraint products_book_type_check
  check (
    nullif(btrim(coalesce(book_type, '')), '') is not null
    and book_type in (
      '기출', '모의고사', 'N제', 'EBS', '주간지', '내신',
      '개념', '워크북',
      '논술'
    )
  );
