-- 상품 등록: 내부 유사 시세 추천 RPC (admin_suggest_register_price)
--
-- 배경(2026-07-20): 처음 등록하는 교재의 판매가를 정할 때 구글 검색으로 시세를 찾던
--   수작업을 대체하는 1단계 — 외부 API 없이 우리 DB의 유사 교재(같은 과목·비슷한 제목)
--   판매가·실판매 이력에서 중앙값을 뽑아 등록 위저드에 힌트로 보여준다.
--
-- 동작:
--   * 제목을 _register_infer_product_meta로 파싱해 과목·브랜드 추출('기타'는 무시).
--     명시 인자(p_subject 등)가 오면 파싱보다 우선 — 등록 위저드 카테고리 선택과 동일 규칙.
--   * 제목 토큰(2자+, 연도 제외, '현우진T'→'현우진' 정규화)의 포함 개수로 유사 상품 스코어링.
--     토큰 절반 이상 일치한 상품만 후보, 브랜드 일치 시 우선 정렬, 상위 6종.
--   * 후보 상품의 books(on_sale·reserved·settled, price 有) 권당 중앙값 → 전체 중앙값.
--     suggested_price는 100원 단위 반올림. avg_discount_rate는 정가 있는 책 기준(없으면 null).
--
-- 변경 요약 (비파괴: CREATE OR REPLACE 신규 함수 1건, 읽기 전용 STABLE):

begin;

create or replace function public.admin_suggest_register_price(
  p_title text,
  p_subject text default null,
  p_brand text default null,
  p_book_type text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_meta record;
  v_subject text;
  v_brand text;
  v_btype text;
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if length(btrim(coalesce(p_title, ''))) < 4 then
    return jsonb_build_object('found', false);
  end if;

  select * into v_meta from public._register_infer_product_meta(p_title);
  -- 명시 카테고리 우선, 파싱 폴백 ('기타'는 필터로 쓰지 않음)
  v_subject := coalesce(nullif(btrim(coalesce(p_subject, '')), ''), nullif(v_meta.subject, '기타'));
  v_brand   := coalesce(nullif(btrim(coalesce(p_brand, '')), ''), nullif(v_meta.brand, '기타'));
  -- 유형은 명시 선택 시에만 필터 (파싱 폴백 '개념'은 오탐이 많아 쓰지 않음)
  v_btype := nullif(btrim(coalesce(p_book_type, '')), '');

  with tokens as (
    -- 제목 토큰: 2자 이상, 연도(20xx) 제외, 강사 접미사 T 제거(현우진T→현우진)
    select distinct regexp_replace(lower(t), '^([가-힣]{2,5})t$', '\1') as t
    from regexp_split_to_table(lower(btrim(p_title)), '\s+') t
    where length(t) >= 2 and t !~ '^20\d{2}$'
  ),
  token_count as (select count(*)::int as total from tokens),
  scored as (
    select p.id, p.title, p.brand,
      (select count(*) from tokens where lower(p.title) like '%' || tokens.t || '%')::int as hits,
      tc.total
    from public.products p, token_count tc
    where (v_subject is null or p.subject = v_subject)
      and (v_btype is null or p.book_type = v_btype)
  ),
  matched as (
    -- 토큰 절반 이상 일치만 후보로 (약한 1~2단어 겹침 남발 방지)
    select s.*,
      (case when v_brand is not null and s.brand = v_brand then 1 else 0 end) as brand_bonus
    from scored s
    where s.hits >= greatest(1, ceil(s.total * 0.5)::int)
  ),
  priced as (
    -- 가격 데이터가 있는 상품만 — 권당 중앙값으로 다권 상품의 쏠림 방지
    select m.id, m.title, m.hits, m.brand_bonus, pb.book_count, pb.median_price, pb.median_ratio
    from matched m
    join lateral (
      select count(*)::int as book_count,
        percentile_cont(0.5) within group (order by b.price) as median_price,
        percentile_cont(0.5) within group (order by b.price::numeric / nullif(b.original_price, 0)::numeric)
          filter (where b.original_price is not null and b.original_price > 0) as median_ratio
      from public.books b
      where b.product_id = m.id
        and b.price is not null
        and b.status in ('on_sale', 'reserved', 'settled')
    ) pb on pb.book_count > 0
    order by m.hits desc, m.brand_bonus desc, m.id desc
    limit 6
  )
  select jsonb_build_object(
    'found', count(*) > 0,
    'product_count', count(*),
    'book_count', coalesce(sum(book_count), 0),
    'suggested_price', round((percentile_cont(0.5) within group (order by median_price)) / 100.0) * 100,
    'avg_discount_rate', round(
      (1 - (percentile_cont(0.5) within group (order by median_ratio) filter (where median_ratio is not null))) * 100
    ),
    'samples', coalesce(jsonb_agg(jsonb_build_object(
        'product_id', id,
        'title', title,
        'price', round(median_price / 100.0) * 100,
        'book_count', book_count
      ) order by hits desc, brand_bonus desc, id desc), '[]'::jsonb)
  )
  into v_result
  from priced;

  return coalesce(v_result, jsonb_build_object('found', false));
end;
$$;

notify pgrst, 'reload schema';

commit;
