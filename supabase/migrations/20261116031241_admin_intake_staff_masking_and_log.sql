-- 교재 등록 담당(알바) 계정 2차 — 전화번호 가리기 · 허용 목록 축소 · 등록자 기록 (2026-11-16)
--
-- 배경(20261116030246 후속):
--   1) 등록 대상 목록(admin_recent_intake_targets / admin_search_register_targets)이 셀러 전화번호를
--      그대로 돌려준다. 등록 담당은 상자를 이름·신청 번호·끝자리로만 찾으면 되므로 전체 번호가 필요 없다.
--   2) 허용 목록 11개 중 admin_intake_catalog_metadata / admin_intake_price_context는 등록 화면이
--      쓰지 않는다(화면에 연결되지 않은 컴포넌트 전용) — 필요 없는 것은 열어 두지 않는다.
--   3) 누가 어떤 책을 등록했는지 남는 곳이 없다(books에 등록자 컬럼 없음). 믿고 맡기기 전에
--      계정별 등록 권수를 확인할 수 있어야 한다.
--
-- 방식:
--   · admin_list_register_targets: 기존 두 목록 함수를 감싸 한 번에 돌려주는 RPC. 등록 담당이면
--     전화번호를 010-****-1234로 가리고, 회원 식별자·회원 이름을 빼고, 전화번호 검색은 끝 4자리만
--     허용한다(가운데 자리를 검색으로 맞혀 보지 못하게). 전체 관리자는 기존과 같은 값.
--     기존 두 함수 본문은 건드리지 않는다 — 등록 담당 허용 목록에서만 뺀다.
--   · admin_get_register_shipment: 등록 담당이면 전화번호를 가려서 반환.
--   · intake_request_allowed: 허용 RPC 11개 → 8개.
--   · book_registration_log + books AFTER INSERT 트리거: 로그인 계정이 책을 등록하면 등록자를 남긴다.
--     RLS 켜고 정책 없음 — 서버(service_role)만 읽는다.
--
-- 영향: 기존 관리자 화면 동작 변화 없음(새 RPC 추가, 기존 RPC 유지). books INSERT에 기록 트리거 1개 추가
--       (기록 실패는 삼켜서 등록을 막지 않는다. 서버·배치처럼 로그인 계정이 없는 INSERT는 건너뛴다).
-- 롤백: intake_request_allowed / admin_get_register_shipment를 20261116030246 정의로 되돌리고,
--       trg_books_log_registration 트리거·새 함수·book_registration_log 테이블을 drop.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 등록 담당에게 보여 줄 전화번호 — 가운데 자리를 가린다
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.mask_phone_for_intake(p_phone text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_phone is null then null
    when length(regexp_replace(p_phone, '[^0-9]', '', 'g')) >= 8 then
      left(regexp_replace(p_phone, '[^0-9]', '', 'g'), 3)
        || '-****-'
        || right(regexp_replace(p_phone, '[^0-9]', '', 'g'), 4)
    else '****'
  end;
$$;

comment on function public.mask_phone_for_intake(text) is
  '등록 담당 화면용 전화번호 표시(010-****-1234). 원본 번호는 바꾸지 않는다.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 등록 대상 목록 — 검색어가 있으면 검색, 없으면 최근 입고 건
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_list_register_targets(
  p_search text default null,
  p_limit integer default 30,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_term text := btrim(coalesce(p_search, ''));
  v_digits text := regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g');
  v_rows jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if v_term <> '' then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.sort_ts desc), '[]'::jsonb)
    into v_rows
    from public.admin_search_register_targets(v_term, p_limit) t;
  else
    v_rows := coalesce(public.admin_recent_intake_targets(p_limit, p_offset), '[]'::jsonb);
  end if;

  if not public.is_intake_staff() then
    return v_rows;
  end if;

  -- 등록 담당: 전화번호는 가려서, 회원 식별자·회원 이름은 빼고 돌려준다.
  -- 검색은 이름·신청 번호·전화번호 끝 4자리로만 맞는 행을 남긴다
  -- (전화번호 일부를 넣어 가며 가린 자리를 알아내지 못하게).
  select coalesce(jsonb_agg(
    (e.elem - 'user_id' - 'member_name')
      || jsonb_build_object(
        'seller_phone', public.mask_phone_for_intake(e.elem ->> 'seller_phone'),
        'is_member', (e.elem ->> 'user_id') is not null
      )
    order by e.ord
  ), '[]'::jsonb)
  into v_rows
  from jsonb_array_elements(v_rows) with ordinality as e(elem, ord)
  where v_term = ''
     or coalesce(e.elem ->> 'seller_name', '') ilike '%' || v_term || '%'
     or coalesce(e.elem ->> 'request_number', '') ilike '%' || v_term || '%'
     or (
       length(v_digits) = 4
       and right(regexp_replace(coalesce(e.elem ->> 'seller_phone', ''), '[^0-9]', '', 'g'), 4) = v_digits
     );

  return v_rows;
end;
$$;

comment on function public.admin_list_register_targets(text, integer, integer) is
  '상품 등록 화면의 등록 대상 목록. 등록 담당(intake)에게는 전화번호를 가리고 회원 식별자를 뺀다. 등록 담당 허용 RPC.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 선택한 검수 건 기본 정보 — 등록 담당에게는 전화번호를 가린다
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_get_register_shipment(p_shipment_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select jsonb_build_object(
    'id', s.id,
    'seller_name', s.seller_name,
    'seller_phone', case
      when public.is_intake_staff() then public.mask_phone_for_intake(s.seller_phone)
      else s.seller_phone
    end,
    'pickup_date', s.pickup_date,
    'status', s.status
  )
  into v_result
  from public.shipments s
  where s.id = p_shipment_id;

  return v_result;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 등록 담당 허용 목록 — 11개 → 8개
--    뺀 것: admin_recent_intake_targets · admin_search_register_targets (전화번호 원본 반환 → 2번으로 대체),
--           admin_intake_catalog_metadata · admin_intake_price_context (등록 화면이 쓰지 않음)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.intake_request_allowed()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('request.method', true), '') = 'POST'
    and coalesce(current_setting('request.path', true), '') ~ (
      '^(/rest/v1)?/rpc/('
      || 'admin_list_register_targets'         -- 등록할 수거 건 목록·검색 (전화번호 가림)
      || '|admin_start_inspection_from_pickup' -- 수거 신청 → 검수 건 연결
      || '|admin_get_register_shipment'        -- 선택한 검수 건 기본 정보 (전화번호 가림)
      || '|admin_search_products_for_register' -- 기존 교재 검색
      || '|admin_suggest_register_price'       -- 가격 제안
      || '|admin_suggest_book_type'            -- 교재 유형 제안
      || '|admin_get_register_sales_history'   -- 판매 이력 참고
      || '|admin_register_customer_inventory'  -- 최종 등록
      || ')$'
    );
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) 등록자 기록 — 로그인 계정이 책을 등록하면 누가 했는지 남긴다
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.book_registration_log (
  book_id bigint primary key references public.books(id) on delete cascade,
  registered_by uuid references auth.users(id) on delete set null,
  registered_by_email text,
  registered_at timestamptz not null default now()
);

comment on table public.book_registration_log is
  '책 등록자 기록(관리자·등록 담당 공통). books INSERT 트리거가 쓴다. 계정을 지워도 이메일 스냅샷은 남는다.';

create index if not exists book_registration_log_actor_idx
  on public.book_registration_log (registered_by, registered_at desc);

-- RLS: 정책을 두지 않는다 — 브라우저에서는 읽지도 쓰지도 못하고 서버(service_role)만 읽는다.
alter table public.book_registration_log enable row level security;
revoke all on table public.book_registration_log from public, anon, authenticated;
grant select on table public.book_registration_log to service_role;

create or replace function public.log_book_registration()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
begin
  -- 서버·배치 INSERT(로그인 계정 없음)는 기록하지 않는다
  if v_uid is null then
    return new;
  end if;

  begin
    insert into public.book_registration_log (book_id, registered_by, registered_by_email)
    values (new.id, v_uid, lower(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), '')))
    on conflict (book_id) do nothing;
  exception when others then
    null; -- 기록 실패가 등록 자체를 막으면 안 된다
  end;

  return new;
end;
$$;

drop trigger if exists trg_books_log_registration on public.books;
create trigger trg_books_log_registration
  after insert on public.books
  for each row
  execute function public.log_book_registration();

-- 직원 계정 화면용 — 계정별 등록 권수(전체·오늘·마지막 등록 시각). 서버(service_role)만 실행.
create or replace function public.admin_staff_registration_stats()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(s.registered_by::text, s.stats), '{}'::jsonb)
  from (
    select
      l.registered_by,
      jsonb_build_object(
        'total', count(*),
        'today', count(*) filter (
          where l.registered_at >= (date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul')
        ),
        'last_at', max(l.registered_at)
      ) as stats
    from public.book_registration_log l
    where l.registered_by is not null
    group by l.registered_by
  ) s;
$$;

comment on function public.admin_staff_registration_stats() is
  '직원 계정 화면용 — 계정(user id)별 책 등록 권수. service_role 전용.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) 실행 권한 — 새 함수는 기본 공개 권한을 회수하고 필요한 역할에만 부여
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public.mask_phone_for_intake(text) from public, anon, authenticated;
revoke all on function public.admin_list_register_targets(text, integer, integer) from public, anon, authenticated;
revoke all on function public.log_book_registration() from public, anon, authenticated;
revoke all on function public.admin_staff_registration_stats() from public, anon, authenticated;

grant execute on function public.mask_phone_for_intake(text) to service_role;
grant execute on function public.admin_list_register_targets(text, integer, integer) to authenticated, service_role;
grant execute on function public.admin_staff_registration_stats() to service_role;

commit;
