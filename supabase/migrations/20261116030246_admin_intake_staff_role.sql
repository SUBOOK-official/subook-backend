-- 교재 등록 담당(알바) 계정 — 상품 등록에 필요한 것만 쓸 수 있는 제한 역할 (2026-11-16)
--
-- 배경: admin_users에 있으면 누구나 is_admin_user()=true라 주문·회원·정산·환불·쿠폰까지
--       전부 접근됐다(역할 컬럼은 있었지만 판정에 쓰이지 않았다). 교재 등록 알바를 고용하면서
--       "등록에 필요한 것만" 열어 줄 장치가 필요하다. 화면에서 메뉴만 숨기는 것은 보안이 아니다 —
--       로그인한 계정은 REST로 어떤 관리자 RPC·테이블이든 직접 부를 수 있기 때문이다.
--
-- 방식: 모든 관리자 권한 검사가 is_admin_user() 한 곳을 지나므로, 여기서
--       role='intake'(등록 담당)은 "허용한 RPC 요청일 때만" 통과시킨다.
--       PostgREST는 요청마다 request.method / request.path를 트랜잭션 설정으로 넣어 준다
--       (https://docs.postgrest.org/en/stable/references/transactions.html — Request Path and Method).
--       · 허용 목록 = 상품 등록 화면이 쓰는 RPC 11개. 그 밖의 RPC·모든 테이블 직접 조회는 거부.
--       · 허용 목록에는 테이블 경로를 넣지 않는다 — 테이블 요청을 통과시키면 PostgREST 임베딩으로
--         연관 테이블(수거 신청의 주소·현관 비밀번호 등)까지 같은 요청 안에서 읽을 수 있다.
--         허용한 RPC는 모두 jsonb 또는 익명 TABLE을 돌려주므로 임베딩 대상이 아니다.
--         ⚠ 새 RPC를 목록에 넣을 때는 반환형이 테이블 행(setof <table>)이 아닌지 확인할 것.
--       · Storage·Edge Function·서버리스 API는 PostgREST 요청이 아니라 경로가 없다 → 기본 거부.
--         사진 업로드만 버킷 정책으로 따로 연다(아래 5).
--
-- 등록 담당에게 열지 않은 것: 새 고객 등록(admin_create_direct_shipment_v2), 상품 이름·가격 수정
--   (admin_update_product_master), 검수 상세, 그 밖의 모든 관리자 기능.
--
-- 영향: 기존 관리자(super/ops/cs) 판정은 그대로다. 새 역할 값·함수·정책만 추가한다.
-- 롤백: is_admin_user()를 2026051301 정의로 되돌리고, role='intake' 행을 지운 뒤
--       새 함수·정책·컬럼을 drop.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 역할 값 'intake' 추가 + 직원 표시용 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.admin_users drop constraint if exists admin_users_role_check;
alter table public.admin_users
  add constraint admin_users_role_check check (role in ('super', 'ops', 'cs', 'intake'));

alter table public.admin_users add column if not exists display_name text;
alter table public.admin_users add column if not exists created_by uuid references auth.users(id) on delete set null;

comment on column public.admin_users.role is
  'super/ops/cs = 전체 관리자, intake = 교재 등록 담당(허용한 등록 RPC만 — intake_request_allowed 참고)';
comment on column public.admin_users.display_name is '직원 계정 화면에 보여 줄 이름·메모';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 등록 담당 판정 / 등록 담당에게 열어 둔 요청
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.is_intake_staff()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1 from public.admin_users where user_id = auth.uid() and role = 'intake'
  );
$$;

comment on function public.is_intake_staff() is
  '로그인한 계정이 교재 등록 담당(role=intake)인지. Storage 업로드 정책과 화면 권한 조회에 쓴다.';

create or replace function public.intake_request_allowed()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('request.method', true), '') = 'POST'
    and coalesce(current_setting('request.path', true), '') ~ (
      '^(/rest/v1)?/rpc/('
      || 'admin_recent_intake_targets'        -- 등록할 수거 건 목록
      || '|admin_search_register_targets'     -- 수거 건 검색
      || '|admin_start_inspection_from_pickup' -- 수거 신청 → 검수 건 연결
      || '|admin_get_register_shipment'       -- 선택한 검수 건 기본 정보
      || '|admin_search_products_for_register' -- 기존 교재 검색
      || '|admin_intake_catalog_metadata'     -- 교재 분류 정보
      || '|admin_intake_price_context'        -- 가격 참고
      || '|admin_suggest_register_price'      -- 가격 제안
      || '|admin_suggest_book_type'           -- 교재 유형 제안
      || '|admin_get_register_sales_history'  -- 판매 이력 참고
      || '|admin_register_customer_inventory' -- 최종 등록
      || ')$'
    );
$$;

comment on function public.intake_request_allowed() is
  '지금 처리 중인 PostgREST 요청이 등록 담당에게 허용한 RPC인지. 테이블 경로·반환형이 테이블 행인 RPC는 넣지 말 것(임베딩으로 연관 테이블이 열린다).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 관리자 판정 — 등록 담당은 허용한 요청일 때만 통과
--    (기존 정의: service_role 이거나 admin_users에 user_id가 있으면 true)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.is_admin_user()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    coalesce(auth.role() = 'service_role', false)
    or exists (
      select 1
      from public.admin_users au
      where au.user_id = auth.uid()
        and (au.role <> 'intake' or public.intake_request_allowed())
    );
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 화면용 권한 조회 + 등록 화면이 테이블을 직접 읽던 자리를 대신할 RPC
-- ─────────────────────────────────────────────────────────────────────────────
-- 관리자 화면이 로그인 직후 부른다: {"role": "admin" | "intake" | null}
-- service_role로 부르면 PostgREST가 넣어 준 경로·메서드를 함께 돌려준다(배포 후 형식 확인용).
create or replace function public.get_admin_access()
returns jsonb
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when coalesce(auth.role() = 'service_role', false) then
      jsonb_build_object(
        'role', 'admin',
        'request_path', current_setting('request.path', true),
        'request_method', current_setting('request.method', true)
      )
    else
      jsonb_build_object(
        'role', (
          select case when au.role = 'intake' then 'intake' else 'admin' end
          from public.admin_users au
          where au.user_id = auth.uid()
          limit 1
        )
      )
  end;
$$;

comment on function public.get_admin_access() is
  '관리자 화면용 권한 조회. role=admin(전체) / intake(등록 담당) / null(권한 없음). 실제 차단은 is_admin_user()가 한다.';

-- 상품 등록 화면이 선택한 검수 건의 기본 정보를 읽는다 (shipments 테이블 직접 조회 대체).
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
    'seller_phone', s.seller_phone,
    'pickup_date', s.pickup_date,
    'status', s.status
  )
  into v_result
  from public.shipments s
  where s.id = p_shipment_id;

  return v_result;
end;
$$;

comment on function public.admin_get_register_shipment(bigint) is
  '상품 등록 화면용 — 검수 건의 셀러명·연락처·수거일·상태만 반환. 등록 담당 허용 RPC.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) 사진 업로드 — 등록 담당은 표지·상세 사진 버킷에 올리기만, 지우기는 자기가 올린 것만
--    (Storage 요청에는 PostgREST 경로가 없어 is_admin_user()가 false다. 기존 관리자 정책은 그대로.)
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists "product-covers intake write" on storage.objects;
create policy "product-covers intake write"
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'product-covers' and (select public.is_intake_staff()));

drop policy if exists "inspection-images intake write" on storage.objects;
create policy "inspection-images intake write"
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'inspection-images' and (select public.is_intake_staff()));

drop policy if exists "product images intake delete own" on storage.objects;
create policy "product images intake delete own"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id in ('product-covers', 'inspection-images')
    and (select public.is_intake_staff())
    and owner_id = (select auth.uid())::text
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) 실행 권한 — 새 함수는 기본 공개 권한을 회수하고 필요한 역할에만 부여 (2026-11-13 감사 기준)
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public.is_intake_staff() from public, anon, authenticated;
revoke all on function public.intake_request_allowed() from public, anon, authenticated;
revoke all on function public.get_admin_access() from public, anon, authenticated;
revoke all on function public.admin_get_register_shipment(bigint) from public, anon, authenticated;

-- is_intake_staff: Storage 정책이 요청자 권한으로 평가하므로 authenticated 필요
grant execute on function public.is_intake_staff() to authenticated, service_role;
-- intake_request_allowed: is_admin_user()(소유자 권한) 안에서만 불린다 — 직접 실행 권한 없음
grant execute on function public.intake_request_allowed() to service_role;
grant execute on function public.get_admin_access() to authenticated, service_role;
grant execute on function public.admin_get_register_shipment(bigint) to authenticated, service_role;

commit;
