-- 식스샵 데이터 마이그레이션을 위해 books / products 테이블의
-- brand / book_type CHECK 제약을 확장한다.
--
-- 식스샵 export 데이터에서 발견된 신규 값:
--   brand:     '메가스터디', '이감', '상상국어평가연구소'
--   book_type: '개념', '워크북'
--
-- 기존 값은 그대로 유지. CHECK 확장은 데이터 손실 없는 non-destructive 작업.

-- ── books.brand ──────────────────────────────────────────────────
alter table public.books drop constraint if exists books_brand_check;
alter table public.books add constraint books_brand_check
  check (brand is null or brand in (
    '시대인재', '강남대성', '대성마이맥', '이투스', 'EBS',
    '메가스터디', '이감', '상상국어평가연구소'
  ));

-- ── books.book_type ──────────────────────────────────────────────
alter table public.books drop constraint if exists books_book_type_check;
alter table public.books add constraint books_book_type_check
  check (book_type is null or book_type in (
    '기출', '모의고사', 'N제', 'EBS', '주간지', '내신',
    '개념', '워크북'
  ));

-- ── products.brand ───────────────────────────────────────────────
alter table public.products drop constraint if exists products_brand_check;
alter table public.products add constraint products_brand_check
  check (
    nullif(btrim(coalesce(brand, '')), '') is not null
    and brand in (
      '시대인재', '강남대성', '대성마이맥', '이투스', 'EBS',
      '메가스터디', '이감', '상상국어평가연구소'
    )
  );

-- ── products.book_type ───────────────────────────────────────────
alter table public.products drop constraint if exists products_book_type_check;
alter table public.products add constraint products_book_type_check
  check (
    nullif(btrim(coalesce(book_type, '')), '') is not null
    and book_type in (
      '기출', '모의고사', 'N제', 'EBS', '주간지', '내신',
      '개념', '워크북'
    )
  );
