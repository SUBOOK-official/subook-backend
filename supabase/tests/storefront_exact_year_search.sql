-- 회귀 테스트: 운영 데이터는 읽기만 하고, 테스트 함수/상품은 임시 스키마에서 실행한다.
-- 실행: DB 연결에서 이 파일 전체를 실행. 모든 임시 객체는 마지막 ROLLBACK으로 제거한다.
begin;

create temp table products as select * from public.products with no data;
create temp table books as select * from public.books with no data;

do $copy_functions$
declare
  function_definition text;
begin
  for function_definition in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('list_public_store_products', 'search_storefront_products')
  loop
    function_definition := replace(function_definition, 'FUNCTION public.', 'FUNCTION pg_temp.');
    function_definition := replace(function_definition, 'public.products', 'pg_temp.products');
    function_definition := replace(function_definition, 'public.books', 'pg_temp.books');
    execute function_definition;
  end loop;
end;
$copy_functions$;

insert into pg_temp.products (id, title, published_year, status, subject, brand, book_type, instructor_name, search_text, search_chosung)
select id, title, published_year, case when id = -6 then 'hidden' else 'on_sale' end, '수학', '시대인재', 'N제', '이신혁',
  lower(title || ' 시대인재 이신혁 강k'), public.extract_chosung(title || ' 시대인재 이신혁')
from (values
  (-1::bigint, '2027 수학 모의고사', 2027),
  (-2::bigint, '2026 수학 모의고사', 2026),
  (-3::bigint, '2025 수학 모의고사', 2025),
  (-4::bigint, '2027 수학 모의고사', 2026), -- 제목이 일치해도 등록 학년도가 다르면 제외
  (-5::bigint, '2027 수학 모의고사', null::integer), -- 학년도 불명 상품 제외
  (-6::bigint, '2027 수학 모의고사', 2027), -- 숨김 상품
  (-7::bigint, '2027 수학 모의고사', 2027) -- 공개 판매 재고가 없는 상품
) fixture(id, title, published_year);

insert into pg_temp.books (id, product_id, title, published_year, status, is_public, condition_grade, price, created_at)
select id, id, title, published_year, 'on_sale', id not in (-6, -7), 'S', 10000, now()
from pg_temp.products;

do $assertions$
declare
  search_term text;
  actual_ids bigint[];
  result_count integer;
begin
  foreach search_term in array array['2027', ' 2027 ', '2027학년도', '2027년', '2027 수학', '수학 2027', '2027학년도 수학']
  loop
    select array_agg(id order by id), max(total_count) into actual_ids, result_count
    from pg_temp.list_public_store_products(p_search => search_term, p_limit => 500);
    assert actual_ids = array[-1::bigint], format('목록 학년도 불일치: %s, ids=%s', search_term, actual_ids);
    assert result_count = 1, '필터 후 total_count도 정확해야 한다';

    select array_agg(id order by id) into actual_ids
    from pg_temp.search_storefront_products(search_term, 500);
    assert actual_ids = array[-7::bigint, -1::bigint], format('자동완성 학년도/숨김 불일치: %s, ids=%s', search_term, actual_ids);
  end loop;

  select array_agg(id order by id) into actual_ids
  from pg_temp.list_public_store_products(p_search => '2026', p_limit => 500);
  assert actual_ids = array[-4::bigint, -2::bigint], '2026도 같은 학년도만 검색되어야 한다';

  assert not exists (select 1 from pg_temp.list_public_store_products(p_search => '2028')), '미등록 학년도는 0건이어야 한다';
  assert not exists (select 1 from pg_temp.search_storefront_products('2028')), '자동완성도 미등록 학년도는 0건이어야 한다';
  assert not exists (select 1 from pg_temp.list_public_store_products(p_search => '2027', p_years => array[2026])), '명시적 연도 필터와 교집합이어야 한다';
  assert not exists (select 1 from pg_temp.list_public_store_products(p_search => '2027', p_instructors => array['다른강사'])), '강사 필터 유지';
  assert not exists (select 1 from pg_temp.list_public_store_products(p_search => '2027', p_title_terms => array['없는시리즈'])), '시리즈 필터 유지';
  assert not exists (select 1 from pg_temp.list_public_store_products(p_search => '2027', p_offset => 1)), '페이지네이션은 학년도 필터 뒤 적용';

  foreach search_term in array array['이신혁', '이신헉', '시데인재', 'ㅅㄷㅇㅈ', '강k', '20270']
  loop
    select count(*) into result_count from pg_temp.list_public_store_products(p_search => search_term, p_limit => 500);
    assert result_count = 5, format('일반/오타/초성/동의어/긴 숫자 검색 회귀: %s, count=%s', search_term, result_count);
    select count(*) into result_count from pg_temp.search_storefront_products(search_term, 500);
    assert result_count = 6, format('자동완성 일반 검색 회귀: %s, count=%s', search_term, result_count);
  end loop;
end;
$assertions$;

select 'storefront_exact_year_search: passed' as result;
rollback;
