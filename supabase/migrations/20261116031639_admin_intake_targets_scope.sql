-- 교재 등록 담당 3차 — 등록 대상 목록을 "진행 중인 건"으로 좁힌다 (2026-11-16)
--
-- 배경: 20261116031241의 admin_list_register_targets는 등록 담당에게 전화번호는 가렸지만
--       검색하면 검수가 끝난 과거 수거 건까지 전부 나왔다(이름 + 끝 4자리 + 날짜).
--       등록 담당이 등록할 일은 진행 중인 건뿐이므로, 끝난 건은 아예 보이지 않게 한다.
--       또 검색어의 _ · % 가 와일드카드로 먹어 "아무 글자" 검색으로 목록을 훑을 수 있었다 → 글자 그대로 비교.
--
-- 변경: 등록 담당(intake)일 때만
--       · 수거 신청은 수거접수·수거중·입고완료·검수중, 직접입고 건은 예정·검수중만 남긴다.
--       · 이름·신청 번호 비교를 ilike 대신 position()으로 (와일드카드 무력화).
--       전체 관리자가 받는 값은 그대로.
-- 영향: 새 화면(등록 담당) 전용 동작. 기존 관리자 동작 변화 없음.
-- 롤백: 20261116031241의 admin_list_register_targets 정의로 되돌린다.

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

  -- 등록 담당: 진행 중인 건만, 전화번호는 가려서, 회원 식별자·회원 이름은 빼고 돌려준다.
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
      (e.elem ->> 'kind' = 'pickup_request'
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

commit;
