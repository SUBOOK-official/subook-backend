-- 검수 건 목록에 연결 상태 노출 (2026-08-10)
--
-- 20260810093000의 사후 감지 그물. 위저드 수정과 자동 연결 트리거로 새 고아는 거의
-- 안 생기지만, 어느 경로로든 빠져나간 건을 목록에서 눈으로 잡을 수 있어야 한다.
--
-- 추가 컬럼:
--   · user_id / member_name       — 연결된 회원
--   · member_link_status          — linked | unlinked | guest
--       linked   : 회원이 붙어 있음
--       unlinked : user_id는 비었는데 같은 번호의 회원이 있음 → 연결 누락 의심(경고)
--       guest    : 같은 번호의 회원이 없음 → 비회원/직접입고, 정상
--   · member_match_count / member_match_names — unlinked일 때 후보 회원
--   · pickup_request_id / request_number      — 브리지된 수거신청
--   · unbridged_request_number    — 브리지가 없는데 같은 번호로 수거일이 ±14일 이내인
--                                   미브리지 수거신청이 있는 경우 그 번호(연결 누락 의심)
--
-- ⚠ ±14일 창은 의도적이다. 재수거 셀러는 같은 번호로 여러 번 신청하는데, 날짜가 먼
--    신청까지 잡으면 별개 배치를 같은 건으로 오인한다.
--    실측: 홍지영 shipment #30(2026-02-24 레거시 입고)과 PU-2607-0001(2026-07-29)은
--    155일 차이 — 붙이면 안 되는 별개 건이고 이 창에서 정상적으로 제외된다.

begin;

drop function if exists public.list_admin_shipments(text, text[], date, date, integer, integer);

create or replace function public.list_admin_shipments(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  id bigint,
  seller_name text,
  seller_phone text,
  pickup_date date,
  status text,
  created_at timestamptz,
  book_count integer,
  user_id uuid,
  member_name text,
  member_link_status text,
  member_match_count integer,
  member_match_names text,
  pickup_request_id bigint,
  request_number text,
  unbridged_request_number text,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $function$
  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits,
      coalesce(cardinality(p_statuses), 0) as status_count
  ),
  filtered_shipments as (
    select
      s.id,
      s.seller_name,
      s.seller_phone,
      s.pickup_date,
      s.status,
      s.created_at,
      s.user_id,
      s.pickup_request_id,
      count(b.id)::integer as book_count
    from public.shipments s
    left join public.books b
      on b.shipment_id = s.id
    cross join params
    where public.is_admin_user()
      and (
        params.search_term = ''
        or s.seller_name ilike '%' || params.search_term || '%'
        or s.seller_phone ilike '%' || params.search_term || '%'
        or (
          params.search_digits <> ''
          and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') like '%' || params.search_digits || '%'
        )
        or s.id::text ilike '%' || params.search_term || '%'
      )
      and (
        params.status_count = 0
        or s.status = any(p_statuses)
      )
      and (
        p_from_date is null
        or s.pickup_date >= p_from_date
      )
      and (
        p_to_date is null
        or s.pickup_date <= p_to_date
      )
    group by
      s.id,
      s.seller_name,
      s.seller_phone,
      s.pickup_date,
      s.status,
      s.created_at,
      s.user_id,
      s.pickup_request_id
  ),
  annotated as (
    select
      fs.*,
      (
        select mp.name from public.member_profiles mp where mp.user_id = fs.user_id
      ) as member_name,
      -- 같은 번호를 쓰는 회원 후보 (user_id가 비었을 때만 의미가 있다)
      coalesce((
        select count(*)::integer
        from public.member_profiles mp
        where mp.personal_data_erased_at is null
          and regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g') <> ''
          and (
            regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g')
              = regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g')
            or regexp_replace(coalesce(mp.verified_phone, ''), '[^0-9]', '', 'g')
              = regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g')
          )
      ), 0) as member_match_count,
      (
        select string_agg(mp.name, ', ' order by mp.created_at)
        from public.member_profiles mp
        where mp.personal_data_erased_at is null
          and regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g') <> ''
          and (
            regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g')
              = regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g')
            or regexp_replace(coalesce(mp.verified_phone, ''), '[^0-9]', '', 'g')
              = regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g')
          )
      ) as member_match_names,
      (
        select pr.request_number
        from public.pickup_requests pr
        where pr.id = fs.pickup_request_id
      ) as request_number,
      -- 브리지가 없는데 날짜가 맞는 미브리지 수거신청이 있으면 연결 누락 의심
      case when fs.pickup_request_id is null then (
        select pr.request_number
        from public.pickup_requests pr
        where pr.merged_into_id is null
          and pr.status <> 'cancelled'
          and regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g') <> ''
          and regexp_replace(coalesce(pr.pickup_recipient_phone, ''), '[^0-9]', '', 'g')
              = regexp_replace(coalesce(fs.seller_phone, ''), '[^0-9]', '', 'g')
          and abs(coalesce(pr.desired_pickup_date, pr.created_at::date) - fs.pickup_date) <= 14
          and not exists (
            select 1 from public.shipments s2 where s2.pickup_request_id = pr.id
          )
        order by abs(coalesce(pr.desired_pickup_date, pr.created_at::date) - fs.pickup_date)
        limit 1
      ) end as unbridged_request_number
    from filtered_shipments fs
  )
  select
    annotated.id,
    annotated.seller_name,
    annotated.seller_phone,
    annotated.pickup_date,
    annotated.status,
    annotated.created_at,
    annotated.book_count,
    annotated.user_id,
    annotated.member_name,
    case
      when annotated.user_id is not null then 'linked'
      when annotated.member_match_count > 0 then 'unlinked'
      else 'guest'
    end as member_link_status,
    annotated.member_match_count,
    annotated.member_match_names,
    annotated.pickup_request_id,
    annotated.request_number,
    annotated.unbridged_request_number,
    count(*) over()::integer as total_count
  from annotated
  order by
    annotated.pickup_date desc,
    annotated.created_at desc,
    annotated.id desc
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 20), 500));
$function$;

grant execute on function public.list_admin_shipments(text, text[], date, date, integer, integer) to authenticated;

commit;
