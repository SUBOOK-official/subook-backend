-- 유형 분류는 서버의 한 규칙으로 제안하고, 근거가 없거나 충돌하면 수동 검토한다.
-- 기존 상품/재고는 이 migration에서 일괄 재분류하지 않는다.
-- 되돌릴 때 등록 RPC와 메타 추론 함수는 직전 migration 정의를 복원한다.
-- 검토 이력은 롤백 시에도 보존한다. 공개 읽기 권한을 부여하지 않는다.
create table public.product_type_reviews (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products(id) on delete cascade,
  title text not null,
  previous_type text,
  book_type text not null check (book_type in ('개념','기출','모의고사','N제','주간지','내신','워크북','논술')),
  method text not null check (method in ('rule','manual','audit_correction')),
  evidence jsonb not null,
  reviewed_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index product_type_reviews_product_idx on public.product_type_reviews(product_id,created_at desc);
alter table public.product_type_reviews enable row level security;
revoke all on public.product_type_reviews from anon,authenticated;
grant select on public.product_type_reviews to authenticated;
create policy product_type_reviews_admin_read on public.product_type_reviews
  for select to authenticated using (public.is_admin_user());
grant all on public.product_type_reviews to service_role;
revoke all on sequence public.product_type_reviews_id_seq from public,anon,authenticated;
grant usage,select on sequence public.product_type_reviews_id_seq to service_role;

create or replace function public._register_classify_book_type(p_title text, p_subject text default null)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  t text := normalize(btrim(coalesce(p_title,'')),nfkc);
  s text := nullif(btrim(p_subject),'');
  kind text;
  rule_id text;
  reason text;
  source_url text;
  candidates text[] := '{}';
begin
  if s is null then
    s := case when t ~ '(생명과학|물리|화학|지구과학|과학탐구)' then '과학'
      when t ~ '(사회문화|경제|정치|한국지리|세계지리|윤리|동아시아사|세계사|사탐|사회탐구)' then '사회'
      when t ~ '(미적분|확률과\s*통계|기하|수학)' then '수학' else '기타' end;
  end if;
  -- 이름이 섞인 세트·복습물과 유형 경계가 겹치는 교재는 우선 보류한다.
  if t = '' then reason := '상품명을 입력하면 유형을 제안합니다.';
  elsif t ~* '(분석서|복습노트|손풀이|스페셜\s*리뷰|어싸|어사|Assignment|ASSINGMENT)' then
    reason := '본교재의 분석·복습·과제 자료입니다. 실제 구성으로 유형을 확인해 주세요.';
  elsif t ~ '간쓸개' and t ~* '(모의고사|패키지|세트|SET)' then
    reason := '간쓸개와 모의고사가 함께 있는 구성입니다. 대표 유형을 직접 확인해 주세요.';
  elsif t ~* '(워크북.*포함|포함.*워크북)' then
    reason := '워크북 포함 세트입니다. 부록이 아닌 본교재 기준으로 유형을 확인해 주세요.';
  elsif t ~* '(EBS|수능특강|수능완성|월간|매월|매달|일간지|인강민철|인\(in\)강민철|인in강민철|단어|어휘|VOCA|워드마스터|WORD\s*MASTER)' then
    reason := '연계·정기 학습·어휘 교재는 유형 경계가 겹칩니다. 목차와 학습 목적을 확인해 주세요.';
  elsif t ~* '(플로우|FLOW|ATG|엑셀러레이터|Accelerator|설맞이\s*아카이브)' then
    reason := '과목·판본에 따라 구성이 달라지는 교재입니다. 해당 판본을 직접 확인해 주세요.';
  elsif t ~ '기출' and t ~ '(모의\s*고사|개념)' then
    reason := '기출과 다른 유형이 함께 명시돼 있습니다. 주된 구성을 확인해 주세요.';
  elsif t ~ '올쏘\s*기출' then
    kind := '내신'; rule_id := 'olsso-school'; reason := '출판사에서 내신 대비 기출 교재로 소개합니다.';
    source_url := 'https://www.bookdonga.com/high/allbook.donga';
  elsif t ~ '수분감' then
    kind := '기출'; rule_id := 'sooboon'; reason := '공식 수분감 시리즈는 평가원·수능 기출 교재입니다.';
    source_url := 'https://www.megastudy.net/teacher_v2/chr/lecture_detailview.asp?CHR_CD=54614&MAKE_FLG=1&tec_cd=woojinmath';
  elsif t ~ '간쓸개' then
    if t ~* '(에센셜|E센셜|간쓸개S(\s|국어|$)|간쓸개\s*스타트)' then
      reason := '간쓸개 파생판입니다. 발행 방식과 해당 판본 구성을 확인해 주세요.';
    else
      kind := '주간지'; rule_id := 'gansseulgae'; reason := '이감에서 간쓸개를 주간 학습지로 소개합니다.';
      source_url := 'https://yigam.co.kr/img/gssg_weekly_preview.pdf';
    end if;
  elsif t ~* '(크럭스|CRUX)' then
    if s in ('수학','과학') then
      kind := 'N제'; rule_id := 'crux-math-science'; reason := '대성의 CRUX 수학·과학은 N제입니다.';
      source_url := 'https://campusm.dshw.co.kr/study/contents.do';
    else reason := 'CRUX는 과목별 구성이 다릅니다. 국어·과목 미확인 교재는 직접 확인해 주세요.'; end if;
  elsif t ~* '(서킷|CIRCUIT|콘스탄트|THE\s*CONSTANT)' then
    kind := '모의고사'; rule_id := 'circuit-constant'; reason := '대성의 공식 회차별 모의고사 시리즈입니다.';
    source_url := 'https://campusm.dshw.co.kr/study/contents.do';
  elsif t ~* '(코넥스|CONNEX)' then
    kind := '개념'; rule_id := 'connex'; reason := '대성에서 실전 개념서로 소개합니다.';
    source_url := 'https://campusm.dshw.co.kr/study/contents.do';
  elsif t ~* '(리바이벌|REVIV[AI]L)' then
    if s in ('과학','사회') then
      kind := 'N제'; rule_id := 'revival-science-social'; reason := '시대인재의 탐구 리바이벌은 N제입니다.';
      source_url := 'https://contents.sdij.com/survival-contents/guide';
    else reason := '리바이벌은 과목별 구성이 다릅니다. 해당 과목의 판본을 확인해 주세요.'; end if;
  elsif t ~ '시대인재' and t ~ '(서바이벌|브릿지|트러스)' and t !~* '(리믹스|이라클|프리서바이벌|Pre-survival)' then
    kind := '모의고사'; rule_id := 'survival'; reason := '시대인재의 서바이벌·브릿지·트러스는 모의고사 시리즈입니다.';
    source_url := 'https://contents.sdij.com/survival-contents/guide';
  elsif t ~* '(킬링\s*캠프|Killing\s*Camp)' then
    kind := '모의고사'; rule_id := 'killing-camp'; reason := '킬링캠프는 회차별 실전 모의고사입니다.';
    source_url := 'https://www.megastudy.net/teacher_v2/t_promotion/202606_pr/0604_math_hwj/main.asp';
  elsif t ~ '강민철의\s*무제' then
    kind := '주간지'; rule_id := 'mincheol-muje'; reason := '강민철 공식 커리큘럼의 파이널 주간지입니다.';
    source_url := 'https://www.megastudy.net/teacher_v2/mega_tcc/view.asp?tec_cd=megabori&tt_num=30045';
  elsif t ~ '현우진' and t ~ '메가스터디' and t ~ '시냅스' then
    kind := '워크북'; rule_id := 'synapse'; reason := '뉴런 복습용 부교재 단품으로, 워크북 유형을 제안합니다.';
    source_url := 'https://api.megastudy.net/teacher_v2/chr/lecture_detailview.asp?CHR_CD=58206&MAKE_FLG=1&tec_cd=woojinmath';
  elsif t ~ '현우진' and t ~ '메가스터디' and t ~* '(드릴|DRILL)' and t !~ '워크북' then
    kind := 'N제'; rule_id := 'drill'; reason := '심화 문제풀이 교재로, N제 유형을 제안합니다.';
    source_url := 'https://m.megastudy.net/teacher_v2/chr/lecture_detailview.asp?CHR_CD=56235&TEC_CD=woojinmath';
  elsif t ~ '(시발점|뉴런)' and t ~ '현우진' and t !~ '워크북' then
    kind := '개념'; rule_id := 'woojin-concept'; reason := '현우진의 개념 학습용 본교재입니다.';
    source_url := 'https://api.megastudy.net/teacher_v2/chr/lecture_detailview.asp?CHR_CD=58206&MAKE_FLG=1&tec_cd=woojinmath';
  else
    if t ~* '(모의\s*고사|모의\s*평가|예비\s*평가|Trial\s*Examination)' then candidates := array_append(candidates,'모의고사'); end if;
    if t ~* '(주간지|주간\s*(교재|과제)|위클리|WEEKLY)' then candidates := array_append(candidates,'주간지'); end if;
    if t ~ '기출' then candidates := array_append(candidates,'기출'); end if;
    if t ~* 'N\s*제' then candidates := array_append(candidates,'N제'); end if;
    if t ~ '워크북' then candidates := array_append(candidates,'워크북'); end if;
    if t ~ '논술' then candidates := array_append(candidates,'논술'); end if;
    if t ~ '(내신|교과서)' then candidates := array_append(candidates,'내신'); end if;
    if t ~ '개념' then candidates := array_append(candidates,'개념'); end if;
    if cardinality(candidates)=1 then
      kind := candidates[1]; rule_id := 'explicit-title'; reason := '상품명에 학습 유형이 명시돼 있습니다. 단품·세트 구성을 확인해 주세요.';
    elsif cardinality(candidates)>1 then
      reason := '여러 유형이 함께 표시돼 있습니다. 본교재의 주된 구성을 직접 확인해 주세요.';
    else reason := '확인된 분류 근거가 없습니다. 공식 설명이나 목차로 유형을 선택해 주세요.'; end if;
  end if;
  -- 알려진 시리즈라도 워크북·모의고사 등 다른 구성 표기가 있으면 확정하지 않는다.
  if kind is not null and rule_id <> 'explicit-title' and rule_id <> 'olsso-school' then
    if (t ~ '워크북' and kind <> '워크북')
      or (t ~* '(모의\s*고사|모의\s*평가|예비\s*평가)' and kind <> '모의고사')
      or (t ~* '(주간지|WEEKLY)' and kind <> '주간지')
      or (t ~ '기출' and kind <> '기출')
      or (t ~* 'N\s*제' and kind <> 'N제') then
      kind := null;
      reason := '시리즈 설명과 다른 구성 표기가 있습니다. 해당 판본의 주된 유형을 확인해 주세요.';
    end if;
  end if;
  if rule_id='woojin-concept' and t ~ '시발점' then
    source_url := 'https://api.megastudy.net/teacher_v2/chr/lecture_detailview.asp?CHR_CD=43298&MAKE_FLG=1&tec_cd=woojinmath';
  end if;
  return jsonb_build_object('book_type',kind,'needs_review',kind is null,'reason',reason,
    'rule_id',rule_id,'source_url',source_url,'version','2026-09-30');
end;
$$;
revoke all on function public._register_classify_book_type(text,text) from public,anon,authenticated;

create or replace function public.admin_classify_book_type(p_title text, p_subject text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  return public._register_classify_book_type(p_title,p_subject);
end;
$$;
revoke all on function public.admin_classify_book_type(text,text) from public,anon;
grant execute on function public.admin_classify_book_type(text,text) to authenticated,service_role;

create or replace function public._register_resolve_book_type(p_item jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  v_title text := btrim(coalesce(p_item->>'title',''));
  v_subject text := btrim(coalesce(p_item->>'subject',''));
  v_result jsonb := public._register_classify_book_type(v_title,v_subject);
  v_selected text := nullif(btrim(p_item->>'book_type'),'');
  v_note text := nullif(btrim(p_item->>'book_type_review_note'),'');
begin
  v_selected := coalesce(v_selected,v_result->>'book_type');
  if v_selected is null then
    raise exception '「%」 유형을 확인해 주세요. 자동으로 개념 유형을 지정하지 않습니다.',v_title;
  end if;
  if v_selected not in ('개념','기출','모의고사','N제','주간지','내신','워크북','논술') then
    raise exception '허용되지 않은 교재 유형입니다: %',v_selected;
  end if;
  if v_selected is distinct from v_result->>'book_type' then
    if coalesce(p_item->'book_type_confirmed','false'::jsonb) <> 'true'::jsonb
      or coalesce(p_item->>'book_type_reviewed_title','') <> v_title
      or coalesce(p_item->>'book_type_reviewed_subject','') <> v_subject
      or length(coalesce(v_note,'')) < 4 or length(v_note)>500 then
      raise exception '「%」 유형을 표지·목차로 확인하고 근거를 4~500자로 적어 주세요. 상품명이 바뀌면 다시 확인해야 합니다.',v_title;
    end if;
    v_result := v_result || jsonb_build_object('method','manual','review_note',v_note);
  else v_result := v_result || jsonb_build_object('method','rule'); end if;
  return v_result || jsonb_build_object('book_type',v_selected);
end;
$$;
revoke all on function public._register_resolve_book_type(jsonb) from public,anon,authenticated;


CREATE OR REPLACE FUNCTION public._register_infer_product_meta(p_title text)
 RETURNS TABLE(year integer, brand text, subject text, book_type text, instructor text)
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select
    nullif((regexp_match(coalesce(p_title, ''), '^(\d{4})'))[1], '')::integer as year,
    case
      when p_title like '%상상국어평가연구소%' then '상상국어평가연구소'
      when p_title like '%시대인재%' then '시대인재'
      when p_title like '%강남대성%' then '강남대성'
      when p_title like '%대성마이맥%' then '대성마이맥'
      when p_title ~ '\m대성\M' then '대성마이맥'
      when p_title like '%이투스%' then '이투스'
      when p_title like '%메가스터디%' then '메가스터디'
      when p_title like '%이감%' then '이감'
      when p_title like '%EBS%' then 'EBS'
      else '기타'
    end as brand,
    case
      when p_title ~ '(생명과학|물리|화학|지구과학|과학탐구)' then '과학'
      when p_title ~ '(사회문화|경제|정치|한국지리|세계지리|윤리|동아시아사|세계사|사탐|사회탐구)' then '사회'
      when p_title ~ '한국사' then '한국사'
      when p_title ~ '(미적분|확률과\s*통계|기하|수학)' then '수학'
      when p_title ~ '(독서|문학|언어와\s*매체|언어와매체|화법과\s*작문|매체\s*N제|국어)' then '국어'
      when p_title ~ '영어' then '영어'
      else '기타'
    end as subject,
    public._register_classify_book_type(p_title)->>'book_type' as book_type,
    (regexp_match(coalesce(p_title, ''), '([가-힣]{2,4})T(?:\s|$)'))[1] as instructor
$function$;

CREATE OR REPLACE FUNCTION public.admin_register_customer_inventory(p_shipment_id bigint, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item jsonb;
  v_opt jsonb;
  v_meta record;
  v_type_review jsonb;
  v_prod record;
  v_group_key text;
  v_product_id bigint;
  v_existing_id bigint;
  v_title text;
  v_original integer;
  v_dtype text;
  v_dvalue integer;
  v_price integer;
  v_cover text;
  v_details text[];
  v_is_public boolean;
  v_qty integer;
  v_row_qty integer;
  v_optname text;
  v_rep_original integer;
  v_options text[];
  v_subject text;
  v_brand text;
  v_btype text;
  v_location text;
  v_serial integer;
  v_serial_start integer;
  v_override integer;
  v_item_books integer;
  v_seq_books integer := 0;
  v_created_serials integer[] := '{}'::integer[];
  v_created_products integer := 0;
  v_created_books integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from public.shipments where id = p_shipment_id) then
    raise exception '고객(수거) 정보를 찾을 수 없습니다.';
  end if;

  -- 시작 일련번호 (2026-07-20): 지정 시 등록 순서대로 start, start+1, ... 순차 배정
  v_serial_start := nullif(btrim(coalesce(p_payload->>'serial_start', '')), '')::integer;
  if v_serial_start is not null and v_serial_start < 1 then
    raise exception '시작 일련번호는 1 이상의 숫자여야 합니다.';
  end if;

  -- ── 신규 교재 ──────────────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'new_products', '[]'::jsonb))
  loop
    v_title := nullif(btrim(v_item->>'title'), '');
    if v_title is null then
      continue;
    end if;

    v_original := nullif(btrim(coalesce(v_item->>'original_price', '')), '')::integer;
    v_dtype := coalesce(nullif(v_item->>'discount_type', ''), 'none');
    v_dvalue := nullif(btrim(coalesce(v_item->>'discount_value', '')), '')::integer;
    v_price := public._register_compute_price(v_original, v_dtype, v_dvalue);
    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;
    v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;
    -- 창고 위치 (2026-07-18: NFKC 정규화 — 전각/반각 통일)
    v_location := nullif(normalize(btrim(coalesce(v_item->>'location', '')), nfkc), '');

    -- 행 수량 (2026-07-22): 같은 구성(옵션 세트)을 수량만큼 반복 생성. 기본 1, 1~999.
    v_row_qty := least(greatest(coalesce(nullif(btrim(coalesce(v_item->>'quantity', '')), '')::integer, 1), 1), 999);
    -- 행별 일련번호 직접 지정 (2026-07-22)
    v_override := nullif(btrim(coalesce(v_item->>'serial_override', '')), '')::integer;
    if v_override is not null and v_override < 1 then
      raise exception '행별 일련번호는 1 이상의 숫자여야 합니다.';
    end if;
    v_item_books := 0;

    select * into v_meta from public._register_infer_product_meta(v_title);
    -- 명시 카테고리가 오면 제목 파싱보다 우선 (빈 값이면 파싱 폴백 — 2026-07-13)
    v_subject := coalesce(nullif(btrim(coalesce(v_item->>'subject', '')), ''), v_meta.subject);
    v_brand   := coalesce(nullif(btrim(coalesce(v_item->>'brand', '')), ''), v_meta.brand);
    v_type_review := public._register_resolve_book_type(v_item);
    v_btype := v_type_review->>'book_type';
    v_group_key := public.storefront_product_group_key(
      v_title, null, v_subject, v_brand, v_btype, v_meta.year, v_meta.instructor
    );

    select id into v_existing_id from public.products where group_key = v_group_key;
    if v_existing_id is null then
      insert into public.products (
        group_key, title, option, subject, brand, book_type,
        published_year, instructor_name, cover_image_url, status
      ) values (
        v_group_key, v_title, null, v_subject, v_brand, v_btype,
        v_meta.year, v_meta.instructor, v_cover, 'selling'
      ) returning id into v_product_id;
      v_created_products := v_created_products + 1;
    else
      v_product_id := v_existing_id;
      if v_cover is not null then
        update public.products
        set cover_image_url = coalesce(cover_image_url, v_cover), updated_at = now()
        where id = v_product_id;
      end if;
    end if;

    insert into public.product_type_reviews(product_id,title,book_type,method,evidence)
    values (v_product_id,v_title,v_btype,v_type_review->>'method',v_type_review);

    v_options := array(
      select btrim(x) from regexp_split_to_table(coalesce(v_item->>'option', ''), ',') x
      where btrim(x) <> ''
    );
    if array_length(v_options, 1) is null then
      v_options := array[null]::text[];
    end if;

    foreach v_optname in array v_options
    loop
      for v_j in 1..v_row_qty
      loop
        -- 일련번호 배정: 행 지정 > 시작 번호 순차 > 시퀀스 자동
        if v_override is not null then
          v_serial := v_override + v_item_books;
        elsif v_serial_start is not null then
          v_serial := v_serial_start + v_seq_books;
        else
          v_serial := public._next_book_serial();
        end if;
        if v_serial = any(v_created_serials) then
          raise exception '일련번호 %가 이번 등록에서 두 번 배정됩니다. 행별 지정 번호가 겹치지 않는지 확인해 주세요.', v_serial;
        end if;
        if exists (select 1 from public.books where serial_number = v_serial) then
          raise exception '일련번호 %가 이미 사용 중입니다. 다른 번호를 입력해 주세요.', v_serial;
        end if;
        insert into public.books (
          shipment_id, title, option, product_id, book_type, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at, serial_number, location
        ) values (
          p_shipment_id, v_title, nullif(v_optname, ''), v_product_id, v_btype, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now(), v_serial, v_location
        );
        if v_override is null and v_serial_start is not null then
          v_seq_books := v_seq_books + 1;
        end if;
        v_item_books := v_item_books + 1;
        v_created_books := v_created_books + 1;
        v_created_serials := v_created_serials || v_serial;
      end loop;
    end loop;
  end loop;

  -- ── 기존 교재 재고 추가 ────────────────────────────────────────
  for v_item in
    select value from jsonb_array_elements(coalesce(p_payload->'existing_additions', '[]'::jsonb))
  loop
    v_product_id := nullif(btrim(coalesce(v_item->>'product_id', '')), '')::bigint;
    if v_product_id is null then
      continue;
    end if;

    select * into v_prod from public.products where id = v_product_id;
    if not found then
      continue;
    end if;

    v_cover := nullif(btrim(coalesce(v_item->>'cover_image_url', '')), '');
    v_details := case
      when v_item ? 'inspection_image_urls'
      then array(
        select btrim(x) from jsonb_array_elements_text(v_item->'inspection_image_urls') x
        where btrim(x) <> ''
      )
      else '{}'::text[]
    end;
    -- 창고 위치 (2026-07-18)
    v_location := nullif(normalize(btrim(coalesce(v_item->>'location', '')), nfkc), '');
    -- 행별 일련번호 직접 지정 (2026-07-22) — 항목(교재) 단위, 항목 내 순서대로 +1
    v_override := nullif(btrim(coalesce(v_item->>'serial_override', '')), '')::integer;
    if v_override is not null and v_override < 1 then
      raise exception '행별 일련번호는 1 이상의 숫자여야 합니다.';
    end if;
    v_item_books := 0;

    select max(original_price) into v_rep_original
    from public.books where product_id = v_product_id and status = 'on_sale';

    if v_cover is not null and v_prod.cover_image_url is null then
      update public.products set cover_image_url = v_cover, updated_at = now() where id = v_product_id;
    end if;

    for v_opt in
      select value from jsonb_array_elements(coalesce(v_item->'options', '[]'::jsonb))
    loop
      v_qty := coalesce(nullif(btrim(coalesce(v_opt->>'quantity', '')), '')::integer, 0);
      if v_qty < 1 then
        continue;
      end if;
      v_optname := nullif(btrim(coalesce(v_opt->>'option', '')), '');
      v_price := nullif(btrim(coalesce(v_opt->>'price', '')), '')::integer;
      v_original := coalesce(nullif(btrim(coalesce(v_opt->>'original_price', '')), '')::integer, v_rep_original);
      v_dtype := coalesce(nullif(v_opt->>'discount_type', ''), 'none');
      v_dvalue := nullif(btrim(coalesce(v_opt->>'discount_value', '')), '')::integer;
      v_is_public := coalesce((v_item->>'is_public')::boolean, false) and v_price is not null;

      for v_i in 1..v_qty
      loop
        -- 일련번호 배정: 행 지정 > 시작 번호 순차 > 시퀀스 자동
        if v_override is not null then
          v_serial := v_override + v_item_books;
        elsif v_serial_start is not null then
          v_serial := v_serial_start + v_seq_books;
        else
          v_serial := public._next_book_serial();
        end if;
        if v_serial = any(v_created_serials) then
          raise exception '일련번호 %가 이번 등록에서 두 번 배정됩니다. 행별 지정 번호가 겹치지 않는지 확인해 주세요.', v_serial;
        end if;
        if exists (select 1 from public.books where serial_number = v_serial) then
          raise exception '일련번호 %가 이미 사용 중입니다. 다른 번호를 입력해 주세요.', v_serial;
        end if;
        insert into public.books (
          shipment_id, title, option, product_id, book_type, original_price, price, condition_grade,
          cover_image_url, inspection_image_urls, status, is_public,
          discount_type, discount_value, inspected_at, serial_number, location
        ) values (
          p_shipment_id, v_prod.title, v_optname, v_product_id, v_prod.book_type, v_original, v_price, 'S',
          v_cover, coalesce(v_details, '{}'::text[]), 'on_sale', v_is_public,
          v_dtype, v_dvalue, now(), v_serial, v_location
        );
        if v_override is null and v_serial_start is not null then
          v_seq_books := v_seq_books + 1;
        end if;
        v_item_books := v_item_books + 1;
        v_created_books := v_created_books + 1;
        v_created_serials := v_created_serials || v_serial;
      end loop;
    end loop;
  end loop;

  -- 수동 시작 배정 시 시퀀스가 뒤처지지 않게 동기화 (자동 채번 exists 루프 비용 방지).
  -- 행별 지정 번호는 시퀀스에 반영하지 않는다 — 멀리 떨어진 번호로 시퀀스를 튀기면
  -- 번호 공간이 낭비되고, 자동 채번은 exists 루프가 충돌을 건너뛰므로 안전하다.
  if v_serial_start is not null and v_seq_books > 0 then
    perform setval('public.books_serial_number_seq',
      greatest(
        (select last_value from public.books_serial_number_seq),
        (v_serial_start + v_seq_books - 1)::bigint
      ));
  end if;

  return jsonb_build_object(
    'success', true,
    'created_products', v_created_products,
    'created_books', v_created_books,
    'created_serials', to_jsonb(v_created_serials)
  );
end;
$function$;
