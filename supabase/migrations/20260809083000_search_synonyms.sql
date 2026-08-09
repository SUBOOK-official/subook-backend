-- 검색 동의어 사전 (2026-08-09, GA 주간 분석 후속)
--
-- 배경(BigQuery 8/4~8/7 실측): 0건 검색 148세션. 최다 0건 검색어 "강k/강K" 40회는
-- 같은 기간 조회수 1위 상품("강대모의고사K 수학", 598뷰)을 가리킴 — 재고 문제가 아니라
-- 검색 미매칭. 과목 약칭도 전멸: 사문 8·생윤 9·정법 4·생2 6·지2 3회 모두 0건인데
-- 정식 명칭("사회문화" 30회)은 정상 매칭.
--
-- 설계: 쿼리 확장이 아니라 "색인 확장". search_synonyms(alias, canonical)에서
-- canonical이 상품 base 검색 텍스트에 포함되면 search_text 끝에 alias를 덧붙인다.
--   · 검색 RPC 2종(list_public_store_products / search_storefront_products)은 불변 —
--     ILIKE·초성·word_similarity 임계(글자수 적응형, 2026-07-23)와 점수식 회귀 위험 0.
--     alias 정확 입력 시 position 매칭(0.8)으로 상위 랭크도 자동.
--   · GIN trgm 인덱스가 덧붙은 alias까지 그대로 커버 — 인덱스 추가 없음.
--   · 별칭 추가/삭제 = 테이블 DML만. AFTER 문장 트리거가 전 상품 search_text를
--     재계산하므로 별도 배포·수동 리프레시 불필요. (products ~수백 행, 전량 재계산 <1s)
--
-- ⚠ 재정의 시 유지: products_refresh_search_columns()와 refresh_all_product_search_text()는
--   반드시 compose_product_search_text() 하나를 공유할 것 (직접 concat으로 갈라지면
--   트리거 경로와 일괄 재계산 경로의 search_text가 드리프트한다).

begin;

-- ── 1) 동의어 테이블 ─────────────────────────────────────────────────────────
create table if not exists public.search_synonyms (
  id bigint generated always as identity primary key,
  -- 사용자가 입력하는 별칭 (예: '사문', '강k'). 소문자 정규화해 저장.
  alias text not null check (btrim(alias) <> ''),
  -- 상품 base 검색 텍스트에 이 문구가 포함되면 alias를 색인에 덧붙인다 (예: '사회문화')
  canonical text not null check (btrim(canonical) <> ''),
  note text,
  created_at timestamptz not null default now(),
  unique (alias, canonical)
);

comment on table public.search_synonyms is
  '검색 별칭 사전 — canonical을 품은 상품의 search_text에 alias를 덧붙임(색인 확장). row 추가/삭제 시 트리거가 전 상품 재색인.';

alter table public.search_synonyms enable row level security;

drop policy if exists search_synonyms_admin_all on public.search_synonyms;
create policy search_synonyms_admin_all on public.search_synonyms
  for all
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ── 2) 검색 텍스트 조립 함수 (트리거·일괄 재계산 공용 단일 소스) ─────────────
create or replace function public.compose_product_search_text(
  p_title text,
  p_option text,
  p_subject text,
  p_brand text,
  p_book_type text,
  p_instructor_name text
)
returns text
language sql
stable
set search_path = public
as $$
  with base as (
    select lower(concat_ws(' ',
      coalesce(p_title, ''),
      coalesce(p_option, ''),
      coalesce(p_subject, ''),
      coalesce(p_brand, ''),
      coalesce(p_book_type, ''),
      coalesce(p_instructor_name, '')
    )) as text
  )
  select case
    when aliases.list is null or aliases.list = '' then base.text
    else base.text || ' ' || aliases.list
  end
  from base
  left join lateral (
    select string_agg(distinct lower(btrim(s.alias)), ' ') as list
    from public.search_synonyms s
    where base.text like '%' || lower(btrim(s.canonical)) || '%'
  ) aliases on true;
$$;

-- ── 3) products 트리거 함수 재정의 — 조립을 공용 함수로 위임 ─────────────────
-- (search_chosung 로직은 2026051512 원본 그대로 — 변경 없음)
create or replace function public.products_refresh_search_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.search_text := public.compose_product_search_text(
    new.title, new.option, new.subject, new.brand, new.book_type, new.instructor_name
  );
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

-- ── 4) 전 상품 일괄 재계산 (동의어 변경 시 트리거가 호출) ────────────────────
-- search_text만 직접 UPDATE — products 트리거는 title 등 원본 컬럼 변경에만 걸려
-- 있어 재귀 발화 없음. 반환값 = 갱신 행 수.
create or replace function public.refresh_all_product_search_text()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.products p
  set search_text = public.compose_product_search_text(
    p.title, p.option, p.subject, p.brand, p.book_type, p.instructor_name
  );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- PostgREST RPC 노출 차단 — 내부(트리거)·관리 경로 전용
revoke all on function public.refresh_all_product_search_text() from public, anon, authenticated;

create or replace function public.search_synonyms_reindex_products()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.refresh_all_product_search_text();
  return null;
end;
$$;

drop trigger if exists trg_search_synonyms_reindex on public.search_synonyms;
create trigger trg_search_synonyms_reindex
  after insert or update or delete on public.search_synonyms
  for each statement
  execute function public.search_synonyms_reindex_products();

-- ── 5) 시드 — 8/4~8/7 0건 검색 실측 + 수능 표준 약칭 ─────────────────────────
-- 원칙: alias가 이미 canonical의 부분 문자열이면 ILIKE로 자연 매칭되므로 넣지 않는다
-- (예: 서바→서바이벌, 미적→미적분). 뜻이 불확실한 은어(킬픽·시네)는 추측 등록 금지.
insert into public.search_synonyms (alias, canonical, note) values
  ('강k',   '강대모의고사k',  '0건 40회 — 조회 1위 상품 미매칭'),
  ('강대k', '강대모의고사k',  null),
  ('사문',  '사회문화',       '0건 8회'),
  ('사문',  '사회·문화',      '중점 표기 변형'),
  ('생윤',  '생활과윤리',     '0건 9회'),
  ('생윤',  '생활과 윤리',    '띄어쓰기 변형'),
  ('윤사',  '윤리와사상',     null),
  ('윤사',  '윤리와 사상',    null),
  ('정법',  '정치와법',       '0건 4회'),
  ('정법',  '정치와 법',      null),
  ('동사',  '동아시아사',     null),
  ('세지',  '세계지리',       null),
  ('한지',  '한국지리',       null),
  ('세사',  '세계사',         null),
  ('생1',   '생명과학1',      null),
  ('생2',   '생명과학2',      '0건 6회'),
  ('지1',   '지구과학1',      null),
  ('지2',   '지구과학2',      '0건 3회'),
  ('지학',  '지구과학',       null),
  ('물1',   '물리학1',        null),
  ('물2',   '물리학2',        null),
  ('화1',   '화학1',          null),
  ('화2',   '화학2',          null),
  ('언매',  '언어와매체',     null),
  ('언매',  '언어와 매체',    null),
  ('화작',  '화법과작문',     null),
  ('화작',  '화법과 작문',    null),
  ('확통',  '확률과통계',     null),
  ('확통',  '확률과 통계',    null),
  ('기벡',  '기하',           '구 교육과정 약칭'),
  ('수1',   '수학1',          null),
  ('수2',   '수학2',          null),
  ('마닳',  '마르고 닳도록',  '이감 기출 시리즈'),
  ('더프',  '더프리미엄',     null),
  ('더프',  '더 프리미엄',    null)
on conflict (alias, canonical) do nothing;

-- 시드 INSERT의 문장 트리거가 이미 전량 재색인하지만, 시드가 전부 conflict로
-- 스킵되는 재실행 케이스까지 보장하도록 명시 호출로 마무리.
select public.refresh_all_product_search_text();

notify pgrst, 'reload schema';

commit;
