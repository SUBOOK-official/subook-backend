-- 유형 선택만으로 등록한다. 연도만 다른 동일 교재에는 운영자가 마지막으로 선택한 유형을 재사용한다.
-- 기존 상품은 재분류하지 않는다. 롤백 시 RPC는 이전 정의로 복원하고 선택 이력/메모리는 보존한다.
create table public.book_type_memory (
  title_key text not null,
  brand text not null,
  subject text not null,
  book_type text not null check (book_type in ('개념','기출','모의고사','N제','주간지','내신','워크북','논술')),
  source_product_id bigint references public.products(id) on delete set null,
  source_title text not null,
  reviewed_by uuid,
  updated_at timestamptz not null default now(),
  primary key (title_key,brand,subject)
);
alter table public.book_type_memory enable row level security;
revoke all on public.book_type_memory from public,anon,authenticated;
grant select on public.book_type_memory to authenticated;
grant all on public.book_type_memory to service_role;
create policy book_type_memory_admin_read on public.book_type_memory
  for select to authenticated using (public.is_admin_user());

create or replace function public._register_book_type_identity(p_title text,p_subject text default null,p_brand text default null)
returns table(title_key text,brand text,subject text)
language sql immutable set search_path=public as $$
  select regexp_replace(
    regexp_replace(
      regexp_replace(lower(normalize(btrim(coalesce(p_title,'')),nfkc)),
        '^(19|20)[0-9]{2}(학년도|년도|년)?', ''),
      '\m(19|20)[0-9]{2}(학년도|년도|년)?\M', '', 'g'),
    '[[:space:][:punct:]]', '', 'g'),
    coalesce(nullif(btrim(p_brand),''),m.brand,'기타'),
    coalesce(nullif(btrim(p_subject),''),m.subject,'기타')
  from public._register_infer_product_meta(p_title) m;
$$;
revoke all on function public._register_book_type_identity(text,text,text) from public,anon,authenticated;

create or replace function public._register_suggest_book_type(p_title text,p_subject text default null,p_brand text default null)
returns jsonb language plpgsql stable set search_path=public as $$
declare
  saved public.book_type_memory%rowtype;
begin
  select m.* into saved from public.book_type_memory m
  join public._register_book_type_identity(p_title,p_subject,p_brand) k
    on (m.title_key,m.brand,m.subject)=(k.title_key,k.brand,k.subject);
  if found then
    return jsonb_build_object('book_type',saved.book_type,'needs_review',false,
      'reason','이전에 같은 교재에 지정한 유형입니다. 연도가 달라도 적용합니다.',
      'rule_id','saved-selection','source_url',null,'source_title',saved.source_title,
      'version','2026-09-30-memory');
  end if;
  return public._register_classify_book_type(p_title,p_subject);
end;
$$;
revoke all on function public._register_suggest_book_type(text,text,text) from public,anon,authenticated;

-- 새 화면은 브랜드도 함께 조회한다. 이미 열린 구버전 화면의 2인자 RPC도 계속 지원한다.
create or replace function public.admin_suggest_book_type(p_title text,p_subject text default null,p_brand text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  return public._register_suggest_book_type(p_title,p_subject,p_brand);
end;
$$;
revoke all on function public.admin_suggest_book_type(text,text,text) from public,anon;
grant execute on function public.admin_suggest_book_type(text,text,text) to authenticated,service_role;

create or replace function public.admin_classify_book_type(p_title text,p_subject text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  return public._register_suggest_book_type(p_title,p_subject,null);
end;
$$;

create or replace function public._register_resolve_book_type(p_item jsonb)
returns jsonb language plpgsql stable set search_path=public as $$
declare
  v_title text := btrim(coalesce(p_item->>'title',''));
  v_result jsonb := public._register_suggest_book_type(v_title,p_item->>'subject',p_item->>'brand');
  v_explicit text := nullif(btrim(p_item->>'book_type'),'');
  v_manual boolean := v_explicit is not null and coalesce(p_item->>'book_type_source','manual') <> 'suggestion';
  v_selected text := case when v_manual then v_explicit else coalesce(v_result->>'book_type',v_explicit) end;
begin
  if v_selected is null then raise exception '「%」 유형을 선택해 주세요.',v_title; end if;
  if v_selected not in ('개념','기출','모의고사','N제','주간지','내신','워크북','논술') then
    raise exception '허용되지 않은 교재 유형입니다: %',v_selected;
  end if;
  -- 구버전 요청의 book_type도 명시적인 선택으로 인정한다. 근거나 확인 체크를 요구하지 않는다.
  -- 자동 제안을 조회한 뒤 다른 운영자가 유형을 바꾼 경우 서버의 최신 선택이 우선한다.
  return v_result || jsonb_build_object('book_type',v_selected,
    'method',case when v_manual then 'manual' else 'rule' end);
end;
$$;

-- 등록 RPC가 남기는 수동 선택/교정 이력만 학습한다. 자동 제안이나 기존 미검증 상품을 학습하지 않는다.
create or replace function public._remember_product_type_review()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.method not in ('manual','audit_correction') then return new; end if;
  insert into public.book_type_memory(title_key,brand,subject,book_type,source_product_id,source_title,reviewed_by)
    select k.title_key,k.brand,k.subject,new.book_type,new.product_id,new.title,new.reviewed_by
    from public.products p cross join lateral public._register_book_type_identity(new.title,p.subject,p.brand) k
    where p.id=new.product_id and k.title_key<>''
  on conflict (title_key,brand,subject) do update
    set book_type=excluded.book_type,source_product_id=excluded.source_product_id,
        source_title=excluded.source_title,reviewed_by=excluded.reviewed_by,updated_at=now();
  return new;
end;
$$;
revoke all on function public._remember_product_type_review() from public,anon,authenticated;
create trigger remember_product_type_review after insert on public.product_type_reviews
  for each row execute function public._remember_product_type_review();

-- 이미 교정·확인된 이력만 최신 선택으로 가져온다. 기존 상품/재고 자체는 변경하지 않는다.
insert into public.book_type_memory(title_key,brand,subject,book_type,source_product_id,source_title,reviewed_by,updated_at)
select distinct on (k.title_key,k.brand,k.subject)
  k.title_key,k.brand,k.subject,r.book_type,r.product_id,r.title,r.reviewed_by,r.created_at
from public.product_type_reviews r join public.products p on p.id=r.product_id
cross join lateral public._register_book_type_identity(r.title,p.subject,p.brand) k
where r.method in ('manual','audit_correction') and r.book_type=p.book_type and k.title_key<>''
order by k.title_key,k.brand,k.subject,r.created_at desc,r.id desc;

CREATE OR REPLACE FUNCTION public.admin_update_product_master(p_product_id bigint, p_title text, p_option text DEFAULT NULL::text, p_original_price integer DEFAULT NULL::integer, p_cover_image_url text DEFAULT NULL::text, p_books jsonb DEFAULT '[]'::jsonb, p_subject text DEFAULT NULL::text, p_brand text DEFAULT NULL::text, p_book_type text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_product record;
  v_title text;
  v_option text;
  v_cover text;
  v_new_group_key text;
  v_conflict_id bigint;
  v_book jsonb;
  v_book_id bigint;
  v_price integer;
  v_book_option text;
  v_grade text;
  v_images text[];
  v_book_row record;
  v_updated_books integer := 0;
  v_updated_grades integer := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_subject text;
  v_brand text;
  v_btype text;
  v_option_uniform boolean;
begin
  if not coalesce(public.is_admin_user(),false) then
    raise exception 'Admin access required';
  end if;

  v_title := nullif(btrim(coalesce(p_title, '')), '');
  if v_title is null then
    raise exception '상품 제목은 비울 수 없습니다.';
  end if;
  v_option := nullif(btrim(coalesce(p_option, '')), '');
  v_cover := nullif(btrim(coalesce(p_cover_image_url, '')), '');

  if p_original_price is not null and p_original_price <= 0 then
    raise exception '정가는 1원 이상이어야 합니다.';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id
  for update;

  if not found then
    raise exception '상품을 찾을 수 없습니다. (id: %)', p_product_id;
  end if;

  -- 카테고리: null/빈값이면 기존 값 유지 (변경 없음 — 구버전 프론트 하위호환)
  v_subject := coalesce(nullif(btrim(coalesce(p_subject, '')), ''), v_product.subject);
  v_brand := coalesce(nullif(btrim(coalesce(p_brand, '')), ''), v_product.brand);
  v_btype := coalesce(nullif(btrim(coalesce(p_book_type, '')), ''), v_product.book_type);

  if nullif(btrim(p_book_type),'') is not null and v_btype not in ('개념','기출','모의고사','N제','주간지','내신','워크북','논술') then
    raise exception '허용되지 않은 교재 유형입니다: %',v_btype;
  end if;

  -- 제목/옵션/카테고리가 바뀌면 group_key 재계산 + 중복 검사
  v_new_group_key := public.storefront_product_group_key(
    v_title, v_option, v_subject, v_brand, v_btype,
    v_product.published_year, v_product.instructor_name
  );

  select id into v_conflict_id
  from public.products
  where group_key = v_new_group_key
    and id <> p_product_id;

  if v_conflict_id is not null then
    raise exception '같은 제목/옵션/메타데이터 조합의 상품(#%)이 이미 존재합니다. 그 상품에서 수정하거나 제목을 다르게 입력하세요.', v_conflict_id;
  end if;

  -- 권별 옵션이 전부 같을 때만 옵션 전파 (2026-07-19: 주간지처럼 권별 옵션이 다른 상품을
  -- 상품 옵션 하나로 덮어쓰는 사고 차단. 단일 옵션 상품의 오타 일괄 수정은 종전대로 동작)
  select count(distinct coalesce(b.option, '')) <= 1
  into v_option_uniform
  from public.books b
  where b.product_id = p_product_id;

  -- 1) 소속 books 공통 필드 반영 (제목 + 균일 시 옵션 + 선택적으로 정가/커버)
  update public.books b
  set title = v_title,
      option = case when v_option_uniform then v_option else b.option end,
      -- 카테고리도 전파 — refresh_storefront_product_status가 대표 book 기준으로
      -- products를 되비추므로 books에 옛 값이 남으면 다음 book 변경 때 원복된다.
      subject = v_subject,
      brand = v_brand,
      book_type = v_btype,
      original_price = coalesce(p_original_price, b.original_price),
      cover_image_url = coalesce(v_cover, b.cover_image_url)
  where b.product_id = p_product_id;

  -- 2) 권별 판매가/옵션명/등급/상세사진 — 1단계 전파보다 뒤에 실행되어 권별 값이 최종 승리
  for v_book in select * from jsonb_array_elements(coalesce(p_books, '[]'::jsonb)) loop
    v_book_id := (v_book->>'id')::bigint;
    if v_book_id is null then
      continue;
    end if;

    select id, status, price, condition_grade into v_book_row
    from public.books
    where id = v_book_id and product_id = p_product_id;

    if not found then
      v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '이 상품 소속이 아님');
      continue;
    end if;

    -- 판매가
    if v_book ? 'price' and v_book->>'price' is not null then
      v_price := (v_book->>'price')::integer;
      if v_price <= 0 then
        v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '판매가는 1원 이상');
      elsif v_book_row.status in ('settled', 'discarded') then
        if v_price <> coalesce(v_book_row.price, -1) then
          v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '정산완료/폐기 책의 가격은 변경 불가');
        end if;
      elsif v_price <> coalesce(v_book_row.price, -1) then
        update public.books set price = v_price where id = v_book_id;
        v_updated_books := v_updated_books + 1;
      end if;
    end if;

    -- 권별 옵션명 (2026-07-23): 'option' 키가 있는 책만 갱신. 빈 값 = 옵션 없음(null).
    -- 옵션명은 실물 표기라 상태(판매완료/폐기 포함)와 무관하게 수정 허용.
    if v_book ? 'option' then
      v_book_option := nullif(btrim(coalesce(v_book->>'option', '')), '');
      update public.books set option = v_book_option where id = v_book_id;
    end if;

    -- 권별 등급 (2026-07-23 A+ 유지 정책): 'condition_grade' 키가 있는 책만 갱신.
    -- 정산완료/폐기 책은 판매·정산 이력의 근거라 가격과 동일하게 변경 금지.
    if v_book ? 'condition_grade' then
      v_grade := nullif(btrim(coalesce(v_book->>'condition_grade', '')), '');
      if v_grade is null or v_grade not in ('S', 'A_PLUS', 'A') then
        v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '유효하지 않은 등급');
      elsif v_book_row.status in ('settled', 'discarded') then
        if v_grade <> coalesce(v_book_row.condition_grade, '') then
          v_skipped := v_skipped || jsonb_build_object('book_id', v_book_id, 'reason', '정산완료/폐기 책의 등급은 변경 불가');
        end if;
      elsif v_grade <> coalesce(v_book_row.condition_grade, '') then
        update public.books set condition_grade = v_grade where id = v_book_id;
        v_updated_grades := v_updated_grades + 1;
      end if;
    end if;

    -- 상세사진 (전달된 경우에만 교체 — 빈 배열이면 전체 삭제 의도로 처리)
    if v_book ? 'inspection_image_urls' and jsonb_typeof(v_book->'inspection_image_urls') = 'array' then
      select coalesce(array_agg(value), '{}'::text[])
      into v_images
      from jsonb_array_elements_text(v_book->'inspection_image_urls');

      update public.books set inspection_image_urls = v_images where id = v_book_id;
    end if;
  end loop;

  -- 3) products 마스터 반영 (books 트리거가 대표 book 기준으로 되비추지만,
  --    on_sale 공개 book이 없는 상품(품절/숨김)은 트리거가 coalesce로 기존 값을
  --    유지하므로 명시적으로 갱신해 둔다. group_key도 여기서만 갱신됨.)
  update public.products
  set title = v_title,
      option = v_option,
      subject = v_subject,
      brand = v_brand,
      book_type = v_btype,
      cover_image_url = coalesce(v_cover, cover_image_url),
      group_key = v_new_group_key,
      updated_at = now()
  where id = p_product_id;

  -- 대표 book 기준 상태/파생값 재계산 (등급 변경 시 대표 등급도 여기서 갱신)
  perform public.refresh_storefront_product_status(p_product_id);

  -- 가격/사진만 편집한 상품은 학습하지 않는다. 유형을 바꿔 저장한 경우 다음 연도에도 재사용한다.
  if nullif(btrim(p_book_type),'') is not null and v_btype is distinct from v_product.book_type then
    insert into public.product_type_reviews(product_id,title,previous_type,book_type,method,evidence)
    values(p_product_id,v_title,v_product.book_type,v_btype,'manual',
      jsonb_build_object('source','product-master-edit'));
  end if;

  return jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'updated_book_prices', v_updated_books,
    'updated_book_grades', v_updated_grades,
    'option_propagated', v_option_uniform,
    'skipped', v_skipped
  );
end;
$function$;
