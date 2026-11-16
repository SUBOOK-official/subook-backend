-- 등록 대상 목록에 "수북 자체 매입" 묶음을 맨 위에 고정 — 등록 담당 계정에서도 고를 수 있게 (2026-11-16)
--
-- 배경: 교재 등록 알바를 고용한 목적은 판매자가 없는 수북 자체 수거·매입 교재(학원 대량 수거분) 등록이다.
--       이런 교재는 예전부터 자체 매입 묶음(shipments.is_direct_purchase = true, "수북 자체 매입")에
--       등록해 왔다 — 팔려도 정산을 만들지 않는다(20260901043000).
--       그런데 ① 최근 입고 목록(admin_recent_intake_targets)은 자체 매입 묶음을 빼고 주고
--       ② 등록 담당용 필터(20261116031639)는 "진행 중인 건"만 남겨서 검수완료 상태인 이 묶음이 걸러졌다.
--       → 등록 담당 계정에서는 자체 수거 교재를 등록할 곳이 보이지 않았다.
--
-- 변경:
--   · admin_list_register_targets
--       - 각 행에 is_direct_purchase(자체 매입 묶음 여부)를 붙인다.
--       - 검색어 없는 첫 쪽에는 자체 매입 묶음을 맨 위에 고정한다(전체 관리자·등록 담당 공통).
--       - 등록 담당 필터에서 자체 매입 묶음은 상태와 무관하게 남긴다(검색도 이름으로 걸린다).
--   · admin_get_register_shipment: is_direct_purchase를 함께 돌려준다(등록 화면 표시용).
--   그 밖의 등록 담당 제한(전화번호 가림·진행 중인 수거 건만·검색 조건·허용 RPC 8개)은 그대로다.
--
-- 영향: 전체 관리자의 기본 목록 맨 위에 자체 매입 묶음 한 줄이 추가된다. 데이터 변경 없음.
-- 롤백: 두 함수를 20261116031639 / 20261116031241 정의로 되돌린다.

begin;

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
  v_own jsonb;
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

  -- 자체 매입 묶음 표시 (판매자 없음 · 정산 없음)
  select coalesce(jsonb_agg(
    e.elem || jsonb_build_object(
      'is_direct_purchase',
      coalesce(
        e.elem ->> 'kind' = 'shipment'
          and exists (
            select 1 from public.shipments s
            where s.id = (e.elem ->> 'ref_id')::bigint and s.is_direct_purchase
          ),
        false
      )
    )
    order by e.ord
  ), '[]'::jsonb)
  into v_rows
  from jsonb_array_elements(v_rows) with ordinality as e(elem, ord);

  -- 검색어 없는 첫 쪽: 자체 매입 묶음을 맨 위에 고정한다 (최근 입고 목록은 이 묶음을 빼고 준다)
  if v_term = '' and coalesce(p_offset, 0) <= 0 then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'kind', 'shipment',
        'ref_id', s.id,
        'request_number', null,
        'seller_name', s.seller_name,
        'seller_phone', s.seller_phone,
        'target_date', s.pickup_date,
        'status', s.status,
        'book_count', (select count(*) from public.books b where b.shipment_id = s.id)::integer,
        'expected_book_count', null,
        'box_count', s.box_count,
        'user_id', s.user_id,
        'sort_ts', s.created_at,
        'is_direct_purchase', true
      )
      order by s.id
    ), '[]'::jsonb)
    into v_own
    from public.shipments s
    where s.is_direct_purchase
      and not exists (
        select 1 from jsonb_array_elements(v_rows) x
        where x ->> 'kind' = 'shipment' and (x ->> 'ref_id')::bigint = s.id
      );
    v_rows := v_own || v_rows;
  end if;

  if not public.is_intake_staff() then
    return v_rows;
  end if;

  -- 등록 담당: 자체 매입 묶음 + 진행 중인 건만, 전화번호는 가려서, 회원 식별자·회원 이름은 빼고 돌려준다.
  -- 검색은 이름·신청 번호(글자 그대로)·전화번호 끝 4자리로만 맞는 행을 남긴다
  -- (전화번호 일부나 와일드카드를 넣어 가며 목록을 훑거나 가린 자리를 알아내지 못하게).
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
  where (
      coalesce((e.elem ->> 'is_direct_purchase')::boolean, false)
      or (e.elem ->> 'kind' = 'pickup_request'
        and e.elem ->> 'status' in ('pickup_scheduled', 'picking_up', 'arrived', 'inspecting'))
      or (e.elem ->> 'kind' = 'shipment'
        and e.elem ->> 'status' in ('scheduled', 'inspecting'))
    )
    and (
      v_term = ''
      or position(lower(v_term) in lower(coalesce(e.elem ->> 'seller_name', ''))) > 0
      or position(lower(v_term) in lower(coalesce(e.elem ->> 'request_number', ''))) > 0
      or (
        length(v_digits) = 4
        and right(regexp_replace(coalesce(e.elem ->> 'seller_phone', ''), '[^0-9]', '', 'g'), 4) = v_digits
      )
    );

  return v_rows;
end;
$$;

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
    'status', s.status,
    'is_direct_purchase', coalesce(s.is_direct_purchase, false)
  )
  into v_result
  from public.shipments s
  where s.id = p_shipment_id;

  return v_result;
end;
$$;

commit;
