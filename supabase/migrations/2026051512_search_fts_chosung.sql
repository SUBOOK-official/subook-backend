-- 상품 검색: FTS + 초성 검색 (P3 Sprint 3-2)
--
-- 1. pg_trgm extension
-- 2. 한글 초성 추출 함수 (extract_chosung)
-- 3. products.search_text + search_chosung generated 컬럼
-- 4. GIN(trgm) 인덱스
-- 5. search_storefront_products RPC

begin;

create extension if not exists pg_trgm;

-- ─────────────────────────────────────────────────────────────────────────────
-- 한글 초성 추출
--   가(0xAC00) ~ 힣(0xD7A3) 범위에서 (code - 0xAC00) / 588로 초성 인덱스 0..18
--   초성 19개: ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ
--   한글 아닌 문자(영문/숫자/공백)는 그대로 보존
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.extract_chosung(p_text text)
returns text
language plpgsql
immutable
parallel safe
as $$
declare
  v_result text := '';
  v_char text;
  v_code integer;
  v_chosung_array text[] := array[
    'ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ',
    'ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'
  ];
  i integer;
begin
  if p_text is null then return ''; end if;

  for i in 1..length(p_text) loop
    v_char := substring(p_text from i for 1);
    v_code := ascii(v_char);
    if v_code >= 44032 and v_code <= 55203 then
      v_result := v_result || v_chosung_array[((v_code - 44032) / 588) + 1];
    else
      v_result := v_result || lower(v_char);
    end if;
  end loop;

  return v_result;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- products에 검색용 generated 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.products
  add column if not exists search_text text;

alter table public.products
  add column if not exists search_chosung text;

-- 기존 row 백필 + 트리거로 자동 유지
create or replace function public.products_refresh_search_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.search_text := lower(concat_ws(' ',
    coalesce(new.title, ''),
    coalesce(new.option, ''),
    coalesce(new.subject, ''),
    coalesce(new.brand, ''),
    coalesce(new.book_type, ''),
    coalesce(new.instructor_name, '')
  ));
  new.search_chosung := public.extract_chosung(concat_ws(' ',
    coalesce(new.title, ''),
    coalesce(new.option, ''),
    coalesce(new.subject, ''),
    coalesce(new.brand, ''),
    coalesce(new.instructor_name, '')
  ));
  return new;
end;
$$;

drop trigger if exists products_set_search_columns on public.products;
create trigger products_set_search_columns
  before insert or update of title, option, subject, brand, book_type, instructor_name
  on public.products
  for each row
  execute function public.products_refresh_search_columns();

-- 기존 row 백필
update public.products
set
  search_text = lower(concat_ws(' ',
    coalesce(title, ''),
    coalesce(option, ''),
    coalesce(subject, ''),
    coalesce(brand, ''),
    coalesce(book_type, ''),
    coalesce(instructor_name, '')
  )),
  search_chosung = public.extract_chosung(concat_ws(' ',
    coalesce(title, ''),
    coalesce(option, ''),
    coalesce(subject, ''),
    coalesce(brand, ''),
    coalesce(instructor_name, '')
  ))
where search_text is null or search_chosung is null;

-- ─────────────────────────────────────────────────────────────────────────────
-- GIN trgm 인덱스
-- ─────────────────────────────────────────────────────────────────────────────
create index if not exists idx_products_search_text_trgm
  on public.products using gin (search_text gin_trgm_ops)
  where status <> 'hidden';

create index if not exists idx_products_search_chosung_trgm
  on public.products using gin (search_chosung gin_trgm_ops)
  where status <> 'hidden';

-- ─────────────────────────────────────────────────────────────────────────────
-- 검색 RPC
--   p_query를 받아 정규화 → 일반 한글이면 search_text 매칭,
--   ㄱㄴㄷ 같은 초성만 있으면 search_chosung 매칭.
--   결과는 trgm similarity + 정확 매칭 우선으로 정렬.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.search_storefront_products(
  p_query text,
  p_limit integer default 30,
  p_offset integer default 0
)
returns table (
  id bigint,
  title text,
  option text,
  subject text,
  brand text,
  book_type text,
  published_year integer,
  instructor_name text,
  cover_image_url text,
  status text,
  match_score real
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_q_chosung text;
  v_is_chosung_only boolean;
begin
  if v_q = '' then
    return;
  end if;

  v_q_chosung := public.extract_chosung(v_q);
  -- 입력이 초성/공백/영문/숫자만으로 이루어졌는지 (일반 한글 음절 없음)
  v_is_chosung_only := v_q !~ '[가-힣]';

  return query
  select
    p.id, p.title, p.option, p.subject, p.brand, p.book_type,
    p.published_year, p.instructor_name, p.cover_image_url, p.status,
    greatest(
      similarity(p.search_text, v_q),
      case when v_is_chosung_only then similarity(p.search_chosung, v_q_chosung) else 0 end,
      case when position(v_q in coalesce(p.search_text, '')) > 0 then 0.8 else 0 end
    )::real as match_score
  from public.products p
  where p.status <> 'hidden'
    and (
      p.search_text ilike '%' || v_q || '%'
      or (v_is_chosung_only and p.search_chosung ilike '%' || v_q_chosung || '%')
      or similarity(p.search_text, v_q) > 0.15
    )
  order by match_score desc, p.created_at desc
  limit greatest(p_limit, 1)
  offset greatest(p_offset, 0);
end;
$$;

grant execute on function public.search_storefront_products(text, integer, integer) to anon, authenticated;

commit;
