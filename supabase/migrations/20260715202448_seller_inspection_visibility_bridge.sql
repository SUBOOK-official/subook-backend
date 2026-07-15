-- 셀러 검수 결과 표면화 브리지 (P0-3)
--
-- 문제 3종:
--   1) 수거신청(pickup_requests)과 실제 검수 단위(shipments→books) 사이에 FK가 없어
--      회원 셀러가 자기 책의 등급·확정가·폐기 여부를 마이페이지에서 볼 방법이 없다.
--      (admin 등록 위저드는 shipments에 user_id도 채우지 않음)
--   2) 폐기 사유가 어디에도 저장되지 않는다 — admin 일괄 폐기 모달이 사유를 입력받지만
--      RPC로 전달되지 않고 버려짐. books에 저장 컬럼 자체가 없음.
--   3) get_my_pickup_requests의 items가 pickup_items(신규 모델에서 항상 0건)만 읽어
--      마이페이지 교재 리스트·판매불가 배너가 dead code 상태.
--
-- 해결:
--   A. shipments.pickup_request_id (nullable FK) — 신청↔검수 브리지.
--   B. books.discard_reason — 폐기 사유 저장.
--   C. admin_start_inspection_from_pickup(p_pickup_request_id) — 수거요청에서
--      연결된 shipment를 멱등 생성(user_id·이름·전화·수거일 자동 세팅) 후 반환.
--      ⚠ 수거요청 status는 건드리지 않음(상태 변경 = 알림톡 실발송 트리거이므로
--      기존 수동 전환 흐름 유지).
--   D. admin_bulk_update_books_status에 p_reason 추가 — 폐기 시 사유 저장,
--      폐기 해제(on_sale/settled 전환) 시 사유 자동 해제.
--   E. get_my_pickup_requests: items를 브리지된 books에서 구성(등급·확정 판매가·
--      상태·폐기사유·검수사진·검수메모). books가 없으면 기존 pickup_items fallback.
--      + box_count/expected_book_count/desired_pickup_date 반환(추후 UI용).

-- ─────────────────────────────────────────────────────────────────────────────
-- A. 브리지 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.shipments
  add column if not exists pickup_request_id bigint null
    references public.pickup_requests(id) on delete set null;

create index if not exists idx_shipments_pickup_request_id
  on public.shipments (pickup_request_id)
  where pickup_request_id is not null;

comment on column public.shipments.pickup_request_id is
  '이 검수(수거) 건의 출처가 된 회원 수거신청. admin_start_inspection_from_pickup이 세팅.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. 폐기 사유
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.books
  add column if not exists discard_reason text null;

comment on column public.books.discard_reason is
  '폐기(판매불가) 사유 — 셀러 마이페이지에 노출. 폐기 해제(등급 재지정/상태 복구) 시 null로 해제.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. 수거요청 → 검수(shipment) 멱등 전환
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

  select id into v_shipment_id
  from public.shipments
  where pickup_request_id = p_pickup_request_id
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
      p_pickup_request_id
    )
    returning id into v_shipment_id;
    v_created := true;
  end if;

  return jsonb_build_object(
    'success', true,
    'shipment_id', v_shipment_id,
    'created', v_created
  );
end;
$$;

grant execute on function public.admin_start_inspection_from_pickup(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. 일괄 상태 변경에 폐기 사유 저장 (시그니처 확장: 2-인자 → 3-인자 default)
--    기존 2-인자 호출은 named param이라 default로 안전 해석됨.
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_bulk_update_books_status(bigint[], text);

create or replace function public.admin_bulk_update_books_status(
  p_ids bigint[],
  p_status text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_success_count integer := 0;
  v_fail_count integer := 0;
  v_failures jsonb := '[]'::jsonb;
  v_msg text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_status not in ('on_sale', 'settled', 'discarded') then
    raise exception 'books.status는 on_sale/settled/discarded만 허용됩니다.';
  end if;

  foreach v_id in array p_ids loop
    begin
      update public.books
      set
        status = p_status,
        -- 폐기 시 사유 저장(빈 문자열은 무시), 폐기가 아닌 상태로 바꾸면 사유 해제
        discard_reason = case
          when p_status = 'discarded' then coalesce(nullif(btrim(p_reason), ''), discard_reason)
          else null
        end
      where id = v_id;
      if found then v_success_count := v_success_count + 1;
      else v_fail_count := v_fail_count + 1;
           v_failures := v_failures || jsonb_build_object('id', v_id, 'reason', 'not found');
      end if;
    exception when others then
      v_fail_count := v_fail_count + 1;
      v_msg := sqlerrm;
      v_failures := v_failures || jsonb_build_object('id', v_id, 'reason', v_msg);
    end;
  end loop;

  return jsonb_build_object(
    'success', true,
    'success_count', v_success_count,
    'fail_count', v_fail_count,
    'failures', v_failures
  );
end;
$$;

grant execute on function public.admin_bulk_update_books_status(bigint[], text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. 셀러 마이페이지 RPC — items를 검수된 books로 구성
--    키 이름은 프론트 mapPickupRequestToShipment가 이미 기대하는 계약
--    (grade/rejection_reason/rejection_photo_urls/inspector_note/inspected_at)에 맞춤.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_my_pickup_requests(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', pr.id,
      'request_number', pr.request_number,
      'status', pr.status,
      'item_count', pr.item_count,
      'box_count', pr.box_count,
      'expected_book_count', pr.expected_book_count,
      'desired_pickup_date', pr.desired_pickup_date,
      'tracking_number', pr.tracking_number,
      'tracking_carrier', pr.tracking_carrier,
      'cj_tracking_status', pr.cj_tracking_status,
      'cj_tracking_status_code', pr.cj_tracking_status_code,
      'cj_tracking_last_checked_at', pr.cj_tracking_last_checked_at,
      'created_at', pr.created_at,
      'updated_at', pr.updated_at,
      'items', coalesce(
        -- 1순위: 브리지된 shipment의 실제 검수 books (등급·확정가·폐기사유·검수사진)
        (
          select jsonb_agg(jsonb_build_object(
            'id', b.id,
            'title', b.title,
            'option', b.option,
            'grade', b.condition_grade,
            'price', b.price,
            'original_price', b.original_price,
            'status', b.status,
            'rejection_reason', case when b.status = 'discarded' then b.discard_reason end,
            'rejection_photo_urls', coalesce(to_jsonb(b.inspection_image_urls), '[]'::jsonb),
            'inspector_note', b.inspection_notes,
            'inspected_at', b.inspected_at
          ) order by (b.status = 'discarded') desc, b.id)
          from public.books b
          join public.shipments s on s.id = b.shipment_id
          where s.pickup_request_id = pr.id
        ),
        -- 2순위: 레거시 pickup_items (교재 개별등록 폐지 전 신청 호환)
        (
          select jsonb_agg(jsonb_build_object(
            'id', pi.id,
            'title', pi.title,
            'subject', pi.subject,
            'brand', pi.brand,
            'book_type', pi.book_type,
            'original_price', pi.original_price,
            'condition_memo', pi.condition_memo,
            'is_manual_entry', pi.is_manual_entry,
            'cover_photo_url', pi.cover_photo_url
          ) order by pi.id)
          from public.pickup_items pi
          where pi.pickup_request_id = pr.id
        ),
        '[]'::jsonb
      )
    ) as row_data
    from public.pickup_requests pr
    where pr.user_id = v_user_id
    order by pr.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.get_my_pickup_requests(integer, integer) to authenticated;

notify pgrst, 'reload schema';
