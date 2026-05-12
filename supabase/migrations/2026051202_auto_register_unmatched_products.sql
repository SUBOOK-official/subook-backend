-- 미매칭 14개 title을 자동 추정으로 products 마스터에 등록 + books 연결 + 노출 처리.
--
-- 추정 로직:
--   year       : 제목 시작 4자리 숫자
--   brand      : 제목에 등장하는 브랜드 키워드 ('대성'은 대성마이맥으로 정규화). 못 찾으면 '기타'
--   subject    : 키워드 매칭 (생명/물리/화학/지구과학 → 과학, 미적분/확률/기하/수학 → 수학, 독서/문학/언매/국어 → 국어 등)
--   book_type  : 명시(모의고사/주간지/기출/N제/...) > 시리즈명(크럭스/CRUX/BLITZ/아폴로/리마인더 → N제, 환생 → 모의고사) > default 개념
--   instructor : 끝의 "한글 2~4자 + T" 패턴

-- 1) products 일괄 INSERT
with raw(title) as (
  values
    ('2025 강남대성 크럭스 CRUX 공통국어 독서와 문학'),
    ('2026 대성 BLITZ 블리츠 생명과학1 홍준용T'),
    ('2026 시대인재 아폴로 Apollo 지구과학1 이신혁T'),
    ('2025 시대인재 가이아 GAIA  Final 파이널 주간지 지구과학1 홍은영T'),
    ('2026 강남대성 RE-MINDER 리마인더 독서 국어'),
    ('2025 강남대성 크럭스 CRUX 수학2'),
    ('2026 강남대성 환생 언어와 매체 백환T'),
    ('2026 이감 이감으로 기출 국어'),
    ('2025 대성마이맥 FOUNDATION 이영수T'),
    ('2027 오르비 다만빠른영어 최석호T'),
    ('2026 시대인재 Mini Test 모의고사 미적분'),
    ('2027 시대인재 Mini Test 모의고사 미적분'),
    ('2026 메가스터디 매체 N제 언어와매체 국어 전형태T'),
    ('2025 강남대성 크럭스 CRUX 확률과 통계')
),
inferred as (
  select
    title,
    nullif((regexp_match(title, '^(\d{4})'))[1], '')::integer as year,
    case
      when title like '%상상국어평가연구소%' then '상상국어평가연구소'
      when title like '%시대인재%' then '시대인재'
      when title like '%강남대성%' then '강남대성'
      when title like '%대성마이맥%' then '대성마이맥'
      when title ~ '\m대성\M' then '대성마이맥'
      when title like '%이투스%' then '이투스'
      when title like '%메가스터디%' then '메가스터디'
      when title like '%이감%' then '이감'
      when title like '%EBS%' then 'EBS'
      else '기타'
    end as brand,
    case
      when title ~ '(생명과학|물리|화학|지구과학|과학탐구)' then '과학'
      when title ~ '(사회문화|경제|정치|한국지리|세계지리|윤리|동아시아사|세계사|사탐|사회탐구)' then '사회'
      when title ~ '한국사' then '한국사'
      when title ~ '(미적분|확률과\s*통계|기하|수학)' then '수학'
      when title ~ '(독서|문학|언어와\s*매체|언어와매체|화법과\s*작문|매체\s*N제|국어)' then '국어'
      when title ~ '영어' then '영어'
      else '기타'
    end as subject,
    case
      when title ~ '모의고사' then '모의고사'
      when title ~ '주간지' then '주간지'
      when title ~ '기출' then '기출'
      when title ~ 'N제' then 'N제'
      when title ~ '워크북' then '워크북'
      when title ~ '논술' then '논술'
      when title ~ '내신' then '내신'
      when title ~ 'EBS' then 'EBS'
      when title ~ '(크럭스|CRUX|블리츠|BLITZ|아폴로|Apollo|리마인더|RE-?MINDER)' then 'N제'
      when title ~ '환생' then '모의고사'
      else '개념'
    end as book_type,
    (regexp_match(title, '([가-힣]{2,4})T(?:\s|$)'))[1] as instructor
  from raw
)
insert into public.products (
  group_key, title, option, subject, brand, book_type,
  published_year, instructor_name, status
)
select
  public.storefront_product_group_key(title, null, subject, brand, book_type, year, instructor),
  title, null, subject, brand, book_type, year, instructor, 'selling'
from inferred
on conflict (group_key) do nothing;

-- 2) books에 product_id 매칭 (위 14개 title 기준 title-only 매칭)
update public.books b
set product_id = p.id
from public.products p
where b.product_id is null
  and b.status = 'on_sale'
  and lower(btrim(b.title)) = lower(btrim(p.title))
  and p.title in (
    '2025 강남대성 크럭스 CRUX 공통국어 독서와 문학',
    '2026 대성 BLITZ 블리츠 생명과학1 홍준용T',
    '2026 시대인재 아폴로 Apollo 지구과학1 이신혁T',
    '2025 시대인재 가이아 GAIA  Final 파이널 주간지 지구과학1 홍은영T',
    '2026 강남대성 RE-MINDER 리마인더 독서 국어',
    '2025 강남대성 크럭스 CRUX 수학2',
    '2026 강남대성 환생 언어와 매체 백환T',
    '2026 이감 이감으로 기출 국어',
    '2025 대성마이맥 FOUNDATION 이영수T',
    '2027 오르비 다만빠른영어 최석호T',
    '2026 시대인재 Mini Test 모의고사 미적분',
    '2027 시대인재 Mini Test 모의고사 미적분',
    '2026 메가스터디 매체 N제 언어와매체 국어 전형태T',
    '2025 강남대성 크럭스 CRUX 확률과 통계'
  );

-- 3) 이제 product 연결된 on_sale 책들을 노출
update public.books
set is_public = true
where status = 'on_sale'
  and product_id is not null
  and is_public = false;
