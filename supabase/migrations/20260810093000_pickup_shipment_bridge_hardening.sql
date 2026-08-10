-- 수거신청 ↔ 검수건 연결 하드닝 (2026-08-10)
--
-- 배경: 회원 수거신청이 들어와도 운영진은 [수거 신청] 탭의 '상품 등록'이 아니라
-- 상품 등록 위저드의 '새 고객 등록'으로 바로 만드는 게 습관이 됐다. 그 경로는
-- shipments에 생 insert라 user_id·pickup_request_id를 구조적으로 못 채운다.
-- 결과: 회원 수거신청 4건 중 3건이 브리지 없이 등록됐고(권현중 #56 / 김영태 #55 /
-- 조이선 #57), 조이선 건은 user_id마저 비어 마이페이지에서 17권이 통째로 사라졌다.
-- (#55/#56은 나중에 손으로 user_id만 채워 넣은 상태 — 확장 불가능한 보정)
--
-- 방향: "다른 버튼을 쓰라"고 교육하는 대신 편한 길이 곧 맞는 길이 되게 한다.
--   1) 위저드 STEP1 검색에 진행 중인 수거신청을 함께 노출 → 고르면 자동 브리지
--      (admin_search_register_targets)
--   2) 새 고객 등록도 RPC 경유 + 같은 번호의 진행 중 수거신청/회원 사전 안내
--      (admin_create_direct_shipment / admin_lookup_seller_context)
--   3) 어떤 경로로 shipments가 생겨도 이름+전화가 회원과 유일 매칭이면 user_id 자동 보정
--      (trg_shipments_auto_link_member) — UI를 우회해도 걸리는 백스톱
--
-- 함께: 하나의 물리적 수거가 여러 수거신청으로 쪼개진 경우(멀티박스 송장 누락 →
-- 운영진이 추가 신청을 임의 생성)를 표현할 방법이 없었다. merged_into_id로 병합해
-- 어느 신청에서 등록을 시작해도 같은 검수 건으로 모이게 한다.
-- 실제 사례: PU-2608-0005(2박스 52권) 중 1박스만 송장이 나가 PU-2608-0006을 따로 만듦.
--
-- ⚠ 재정의 시 유지 필수:
--   - admin_start_inspection_from_pickup의 root(merged_into_id) 해석
--   - auto_link_shipment_member의 "이름+전화 동시 일치 & 유일 매칭" 조건
--     (전화번호만으로 매칭하면 안 된다 — 같은 번호를 쓰는 회원이 실제로 최대 3명 있다)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- A. 수거신청 병합 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.pickup_requests
  add column if not exists merged_into_id bigint null
    references public.pickup_requests(id) on delete set null;

create index if not exists idx_pickup_requests_merged_into_id
  on public.pickup_requests (merged_into_id)
  where merged_into_id is not null;

alter table public.pickup_requests
  drop constraint if exists pickup_requests_merged_into_not_self;
alter table public.pickup_requests
  add constraint pickup_requests_merged_into_not_self
    check (merged_into_id is null or merged_into_id <> id);

comment on column public.pickup_requests.merged_into_id is
  '이 신청이 흡수된 원본 수거신청. 하나의 물리적 수거가 여러 신청으로 쪼개진 경우(박스 누락 재접수 등) 사용. 병합은 1단계만 허용 — 병합된 건을 다시 병합 대상으로 쓸 수 없다.';

-- 병합 root 해석 (1단계 보장이므로 coalesce 한 번이면 충분)
create or replace function public.pickup_request_root_id(p_id bigint)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(pr.merged_into_id, pr.id)
  from public.pickup_requests pr
  where pr.id = p_id;
$$;

grant execute on function public.pickup_request_root_id(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. 회원 자동 연결 백스톱 — 어떤 경로로 shipments가 생겨도 걸린다
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.auto_link_shipment_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_name text;
  v_users uuid[];
begin
  if new.user_id is not null then
    return new;
  end if;

  v_phone := regexp_replace(coalesce(new.seller_phone, ''), '[^0-9]', '', 'g');
  v_name := regexp_replace(coalesce(new.seller_name, ''), '\s', '', 'g');

  if v_phone = '' or v_name = '' then
    return new;
  end if;

  -- 이름+전화 동시 일치 & 유일 매칭일 때만 연결.
  -- 전화번호만으로 매칭하면 같은 번호를 공유하는 회원(가족 등)에게 남의 검수 결과가
  -- 노출될 수 있다 — 실제로 한 번호에 3명까지 묶인 케이스가 있다.
  select array_agg(mp.user_id)
  into v_users
  from public.member_profiles mp
  where mp.personal_data_erased_at is null
    and regexp_replace(coalesce(mp.name, ''), '\s', '', 'g') = v_name
    and (
      regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') = v_phone
      or regexp_replace(coalesce(mp.verified_phone, ''), '[^0-9]', '', 'g') = v_phone
    );

  if coalesce(array_length(v_users, 1), 0) = 1 then
    new.user_id := v_users[1];
  end if;

  return new;
end;
$$;

comment on function public.auto_link_shipment_member() is
  'shipments INSERT 시 user_id가 비어 있으면 이름+전화 유일 매칭 회원으로 자동 연결 (2026-08-10)';

drop trigger if exists trg_shipments_auto_link_member on public.shipments;
create trigger trg_shipments_auto_link_member
  before insert on public.shipments
  for each row
  execute function public.auto_link_shipment_member();

-- ─────────────────────────────────────────────────────────────────────────────
-- C. 수거신청 → 검수건 전환을 root 기준으로 (병합된 신청 어디서 눌러도 같은 검수 건)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_start_inspection_from_pickup(
  p_pickup_request_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr record;
  v_root_id bigint;
  v_shipment_id bigint;
  v_created boolean := false;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_pr
  from public.pickup_requests
  where id = p_pickup_request_id;

  if not found then
    raise exception '수거 요청을 찾을 수 없습니다.';
  end if;

  if v_pr.status = 'cancelled' then
    raise exception '취소된 수거 요청은 검수로 전환할 수 없습니다.';
  end if;

  -- 병합된 신청이면 원본(root)의 검수 건으로 합류시킨다.
  v_root_id := coalesce(v_pr.merged_into_id, v_pr.id);
  if v_root_id <> p_pickup_request_id then
    select * into v_pr from public.pickup_requests where id = v_root_id;
  end if;

  select id into v_shipment_id
  from public.shipments
  where pickup_request_id = v_root_id
  order by id
  limit 1;

  if v_shipment_id is null then
    insert into public.shipments (
      user_id, seller_name, seller_phone, pickup_date, status, pickup_request_id
    ) values (
      v_pr.user_id,
      v_pr.pickup_recipient_name,
      v_pr.pickup_recipient_phone,
      coalesce(v_pr.desired_pickup_date, current_date),
      'scheduled',
      v_root_id
    )
    returning id into v_shipment_id;
    v_created := true;
  end if;

  return jsonb_build_object(
    'success', true,
    'shipment_id', v_shipment_id,
    'pickup_request_id', v_root_id,
    'created', v_created
  );
end;
$$;

grant execute on function public.admin_start_inspection_from_pickup(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. 병합 / 병합 해제
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_merge_pickup_requests(
  p_source_id bigint,
  p_target_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source record;
  v_target record;
  v_target_shipment bigint;
  v_removed integer := 0;
  v_moved integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_source_id = p_target_id then
    raise exception '같은 수거신청끼리는 병합할 수 없습니다.';
  end if;

  select * into v_source from public.pickup_requests where id = p_source_id for update;
  if not found then
    raise exception '병합할 수거신청을 찾을 수 없습니다.';
  end if;

  select * into v_target from public.pickup_requests where id = p_target_id for update;
  if not found then
    raise exception '병합 대상 수거신청을 찾을 수 없습니다.';
  end if;

  if v_source.merged_into_id is not null then
    raise exception '이미 다른 신청에 병합된 수거신청입니다.';
  end if;

  if v_target.merged_into_id is not null then
    raise exception '병합 대상이 이미 다른 신청에 병합돼 있습니다. 원본 신청에 병합해 주세요.';
  end if;

  if exists (select 1 from public.pickup_requests where merged_into_id = p_source_id) then
    raise exception '이 신청에는 이미 병합된 하위 신청이 있어 병합할 수 없습니다.';
  end if;

  if v_source.user_id is distinct from v_target.user_id then
    raise exception '서로 다른 회원의 수거신청은 병합할 수 없습니다.';
  end if;

  select id into v_target_shipment
  from public.shipments
  where pickup_request_id = p_target_id
  order by id
  limit 1;

  -- 병합되는 쪽에 책 없는 빈 검수 건이 있으면 정리한다.
  -- (양쪽에서 '상품 등록'을 눌러 빈 껍데기가 생긴 경우 — 목록에 유령 행으로 남는다)
  delete from public.shipments s
  where s.pickup_request_id = p_source_id
    and not exists (select 1 from public.books b where b.shipment_id = s.id);
  get diagnostics v_removed = row_count;

  -- 책이 들어 있는 검수 건은 원본 쪽으로 이관.
  -- 대상에 이미 검수 건이 있으면 둘 다 원본에 매달린다(권수 기준으로 합산되므로 안전).
  update public.shipments
  set pickup_request_id = p_target_id
  where pickup_request_id = p_source_id;
  get diagnostics v_moved = row_count;

  update public.pickup_requests
  set merged_into_id = p_target_id,
      updated_at = now()
  where id = p_source_id;

  return jsonb_build_object(
    'success', true,
    'source_id', p_source_id,
    'target_id', p_target_id,
    'target_shipment_id', v_target_shipment,
    'moved_shipments', v_moved,
    'removed_empty_shipments', v_removed
  );
end;
$$;

grant execute on function public.admin_merge_pickup_requests(bigint, bigint) to authenticated;

create or replace function public.admin_unmerge_pickup_request(
  p_pickup_request_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 검수 건은 원본에 남는다(책이 어느 박스에서 왔는지 DB가 알 수 없다).
  -- 되돌린 뒤 필요하면 운영자가 검수 건을 다시 지정해야 한다.
  update public.pickup_requests
  set merged_into_id = null,
      updated_at = now()
  where id = p_pickup_request_id
    and merged_into_id is not null;

  if not found then
    raise exception '병합된 수거신청이 아닙니다.';
  end if;

  return jsonb_build_object('success', true, 'pickup_request_id', p_pickup_request_id);
end;
$$;

grant execute on function public.admin_unmerge_pickup_request(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. 위저드 STEP1 통합 검색 — 검수 건 + 진행 중 수거신청을 한 목록으로
--    한 물리적 수거가 한 행으로만 나오도록:
--      · 수거신청은 root(병합 안 된 것)만
--      · 검수 건은 수거신청에 안 붙은 것(직접입고·레거시)만
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_search_register_targets(text, integer);

create or replace function public.admin_search_register_targets(
  p_search text default null,
  p_limit integer default 20
)
returns table (
  kind text,
  ref_id bigint,
  request_number text,
  seller_name text,
  seller_phone text,
  target_date date,
  status text,
  book_count integer,
  expected_book_count integer,
  box_count integer,
  user_id uuid,
  member_name text,
  sort_ts timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      btrim(coalesce(p_search, '')) as term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as digits
  )
  select * from (
    -- 진행 중인 회원 수거신청 (이 행을 고르면 프론트가 브리지 RPC를 태운다)
    select
      'pickup_request'::text as kind,
      pr.id as ref_id,
      pr.request_number,
      pr.pickup_recipient_name as seller_name,
      pr.pickup_recipient_phone as seller_phone,
      pr.desired_pickup_date as target_date,
      pr.status,
      coalesce((
        select count(*)::integer
        from public.books b
        join public.shipments s on s.id = b.shipment_id
        where s.pickup_request_id = pr.id
      ), 0) as book_count,
      pr.expected_book_count,
      coalesce(pr.box_count, 0)
        + coalesce((
            select sum(coalesce(c.box_count, 0))::integer
            from public.pickup_requests c
            where c.merged_into_id = pr.id
          ), 0) as box_count,
      pr.user_id,
      mp.name as member_name,
      pr.created_at as sort_ts
    from public.pickup_requests pr
    cross join params
    left join public.member_profiles mp on mp.user_id = pr.user_id
    where public.is_admin_user()
      and pr.status <> 'cancelled'
      and pr.merged_into_id is null
      and (
        params.term = ''
        or pr.pickup_recipient_name ilike '%' || params.term || '%'
        or pr.pickup_recipient_phone ilike '%' || params.term || '%'
        or pr.request_number ilike '%' || params.term || '%'
        or (
          params.digits <> ''
          and regexp_replace(pr.pickup_recipient_phone, '[^0-9]', '', 'g') like '%' || params.digits || '%'
        )
      )

    union all

    -- 직접입고·레거시 검수 건 (수거신청에 안 붙은 것만 — 붙은 건 위쪽에서 이미 나온다)
    select
      'shipment'::text as kind,
      s.id as ref_id,
      null::text as request_number,
      s.seller_name,
      s.seller_phone,
      s.pickup_date as target_date,
      s.status,
      coalesce((
        select count(*)::integer from public.books b where b.shipment_id = s.id
      ), 0) as book_count,
      null::integer as expected_book_count,
      s.box_count,
      s.user_id,
      mp.name as member_name,
      s.created_at as sort_ts
    from public.shipments s
    cross join params
    left join public.member_profiles mp on mp.user_id = s.user_id
    where public.is_admin_user()
      and s.pickup_request_id is null
      and (
        params.term = ''
        or s.seller_name ilike '%' || params.term || '%'
        or s.seller_phone ilike '%' || params.term || '%'
        or (
          params.digits <> ''
          and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') like '%' || params.digits || '%'
        )
      )
  ) merged
  order by sort_ts desc
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

grant execute on function public.admin_search_register_targets(text, integer) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. 새 고객 등록 사전 조회 + 생성 RPC
--    (프론트의 shipments 생 insert를 대체 — 회원 연결과 중복 경고를 서버가 책임진다)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_lookup_seller_context(
  p_seller_name text default null,
  p_seller_phone text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_name text;
  v_members jsonb;
  v_requests jsonb;
  v_shipments jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_phone := regexp_replace(coalesce(p_seller_phone, ''), '[^0-9]', '', 'g');
  v_name := regexp_replace(coalesce(p_seller_name, ''), '\s', '', 'g');

  if v_phone = '' then
    return jsonb_build_object('members', '[]'::jsonb, 'pending_requests', '[]'::jsonb, 'existing_shipments', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mp.user_id,
    'name', mp.name,
    'phone', mp.phone,
    'email', mp.email,
    'name_matches', v_name <> '' and regexp_replace(coalesce(mp.name, ''), '\s', '', 'g') = v_name
  ) order by mp.created_at), '[]'::jsonb)
  into v_members
  from public.member_profiles mp
  where mp.personal_data_erased_at is null
    and (
      regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') = v_phone
      or regexp_replace(coalesce(mp.verified_phone, ''), '[^0-9]', '', 'g') = v_phone
    );

  -- 아직 검수로 안 넘어간 진행 중 수거신청 (있으면 새로 만들지 말고 이걸 골라야 한다)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pr.id,
    'request_number', pr.request_number,
    'status', pr.status,
    'desired_pickup_date', pr.desired_pickup_date,
    'expected_book_count', pr.expected_book_count,
    'box_count', pr.box_count
  ) order by pr.created_at desc), '[]'::jsonb)
  into v_requests
  from public.pickup_requests pr
  where pr.merged_into_id is null
    and pr.status not in ('cancelled', 'completed')
    and regexp_replace(coalesce(pr.pickup_recipient_phone, ''), '[^0-9]', '', 'g') = v_phone;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'pickup_date', s.pickup_date,
    'status', s.status,
    'book_count', (select count(*) from public.books b where b.shipment_id = s.id)
  ) order by s.created_at desc), '[]'::jsonb)
  into v_shipments
  from public.shipments s
  where regexp_replace(coalesce(s.seller_phone, ''), '[^0-9]', '', 'g') = v_phone;

  return jsonb_build_object(
    'members', v_members,
    'pending_requests', v_requests,
    'existing_shipments', v_shipments
  );
end;
$$;

grant execute on function public.admin_lookup_seller_context(text, text) to authenticated;

create or replace function public.admin_create_direct_shipment(
  p_seller_name text,
  p_seller_phone text,
  p_pickup_date date,
  p_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shipment record;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if btrim(coalesce(p_seller_name, '')) = '' or btrim(coalesce(p_seller_phone, '')) = '' then
    raise exception '이름과 연락처는 필수입니다.';
  end if;

  if p_pickup_date is null then
    raise exception '수거 일자는 필수입니다.';
  end if;

  -- p_user_id가 오면 그대로 사용(운영자가 후보 중 고른 경우),
  -- 없으면 trg_shipments_auto_link_member가 이름+전화 유일 매칭으로 채운다.
  insert into public.shipments (user_id, seller_name, seller_phone, pickup_date, status)
  values (p_user_id, btrim(p_seller_name), btrim(p_seller_phone), p_pickup_date, 'scheduled')
  returning * into v_shipment;

  return jsonb_build_object(
    'success', true,
    'shipment', jsonb_build_object(
      'id', v_shipment.id,
      'seller_name', v_shipment.seller_name,
      'seller_phone', v_shipment.seller_phone,
      'pickup_date', v_shipment.pickup_date,
      'status', v_shipment.status,
      'user_id', v_shipment.user_id
    ),
    'linked_member', v_shipment.user_id is not null
  );
end;
$$;

grant execute on function public.admin_create_direct_shipment(text, text, date, uuid) to authenticated;

commit;
