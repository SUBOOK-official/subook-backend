begin;

-- CJ V3.9.4 §1.2.4: 01 극소 / 02 소 / 03 중 / 04 대1 / 07 대2.
-- 기존 신청은 NULL(미확인) 유지. 운영자가 확인하기 전에는 CJ 접수하지 않는다.
alter table public.pickup_requests add column box_type_codes text[];
comment on column public.pickup_requests.box_type_codes is '박스 순서별 CJ 규격 코드. NULL은 기존 신청의 규격 미확인이며 극소로 간주하지 않는다.';

create function public.valid_pickup_box_types(p_codes text[], p_count integer)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(p_count between 1 and 5 and cardinality(p_codes) = p_count
    and array_ndims(p_codes) = 1 and array_lower(p_codes, 1) = 1
    and array_position(p_codes, null) is null
    and p_codes <@ array['01','02','03','04','07']::text[], false);
$$;
alter table public.pickup_requests add constraint pickup_requests_box_type_codes_valid
  check (box_type_codes is null or public.valid_pickup_box_types(box_type_codes, box_count));

-- 기존 테이블 RLS(본인 읽기/관리자 관리)를 그대로 유지한다. 새 공개 쓰기 권한은 없다.
create function public.require_pickup_box_types()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.box_type_codes is null then
    select array_agg(value order by ord) into new.box_type_codes
    from jsonb_array_elements_text(nullif(current_setting('subook.pickup_box_types', true), '')::jsonb)
      with ordinality as selected(value, ord);
  end if;
  if not public.valid_pickup_box_types(new.box_type_codes, new.box_count) then
    raise exception '박스 규격 선택이 필요합니다. 새로고침 후 박스별 CJ 규격을 선택해 주세요.';
  end if;
  return new;
end;
$$;
revoke all on function public.require_pickup_box_types() from public, anon, authenticated;
create trigger pickup_requests_require_box_types before insert on public.pickup_requests
  for each row execute function public.require_pickup_box_types();

-- v2가 가진 OTP·차단·계좌 자동등록·수수료 동의 검증을 그대로 호출한다.
create function public.submit_pickup_request_v3(
  p_pickup_recipient_name text, p_pickup_recipient_phone text, p_pickup_postal_code text,
  p_pickup_address_line1 text, p_pickup_address_line2 text, p_pickup_memo text,
  p_settlement_bank_name text, p_settlement_account_number text, p_settlement_account_holder text,
  p_items jsonb, p_box_type_codes text[], p_settlement_account_id bigint default null,
  p_pickup_email text default null, p_pickup_entrance_password text default null,
  p_desired_pickup_date date default null, p_expected_book_count integer default null,
  p_box_count integer default null, p_policy_agreed boolean default false, p_fee_policy_version text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  if not public.valid_pickup_box_types(p_box_type_codes, p_box_count) then
    raise exception '박스 수(1~5개)와 각 박스의 CJ 규격을 확인해 주세요.';
  end if;
  perform set_config('subook.pickup_box_types', to_jsonb(p_box_type_codes)::text, true);
  v_result := public.submit_pickup_request_v2(
    p_pickup_recipient_name, p_pickup_recipient_phone, p_pickup_postal_code,
    p_pickup_address_line1, p_pickup_address_line2, p_pickup_memo,
    p_settlement_bank_name, p_settlement_account_number, p_settlement_account_holder,
    p_items, p_settlement_account_id, p_pickup_email, p_pickup_entrance_password,
    p_desired_pickup_date, p_expected_book_count, p_box_count, p_policy_agreed, p_fee_policy_version);
  perform set_config('subook.pickup_box_types', '', true);
  return v_result || jsonb_build_object('box_type_codes', p_box_type_codes);
end;
$$;
revoke all on function public.submit_pickup_request_v3(text,text,text,text,text,text,text,text,text,jsonb,text[],bigint,text,text,date,integer,integer,boolean,text) from public, anon;
grant execute on function public.submit_pickup_request_v3(text,text,text,text,text,text,text,text,text,jsonb,text[],bigint,text,text,date,integer,integer,boolean,text) to authenticated;

-- 기존 목록의 병합·신뢰 신호·검색·정렬을 보존하는 확장 래퍼.
create function public.list_admin_pickup_requests_v2(
  p_search text default null, p_statuses text[] default null, p_from_date date default null,
  p_to_date date default null, p_limit integer default 30, p_offset integer default 0
)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('box_type_codes', pr.box_type_codes) order by r.ordinality)
    from public.list_admin_pickup_requests(p_search,p_statuses,p_from_date,p_to_date,p_limit,p_offset) with ordinality r
    join public.pickup_requests pr on pr.id = r.id), '[]'::jsonb);
end;
$$;
revoke all on function public.list_admin_pickup_requests_v2(text,text[],date,date,integer,integer) from public, anon;
grant execute on function public.list_admin_pickup_requests_v2(text,text[],date,date,integer,integer) to authenticated;

create function public.get_my_pickup_requests_v2(p_limit integer default 20, p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다.'; end if;
  return coalesce((select jsonb_agg(r.value || jsonb_build_object('box_type_codes', pr.box_type_codes) order by r.ordinality)
    from jsonb_array_elements(public.get_my_pickup_requests(p_limit,p_offset)) with ordinality r
    left join public.pickup_requests pr on pr.id::text = r.value->>'id' and pr.user_id = auth.uid()), '[]'::jsonb);
end;
$$;
revoke all on function public.get_my_pickup_requests_v2(integer,integer) from public, anon;
grant execute on function public.get_my_pickup_requests_v2(integer,integer) to authenticated;

create function public.admin_set_pickup_box_types(p_request_id bigint, p_box_type_codes text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_request public.pickup_requests%rowtype;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  select * into v_request from public.pickup_requests where id = p_request_id for update;
  if not found then raise exception '수거 신청을 찾을 수 없습니다.'; end if;
  if v_request.status not in ('pending','pickup_scheduled') then raise exception '현재 상태에서는 규격을 변경할 수 없습니다.'; end if;
  if not public.valid_pickup_box_types(p_box_type_codes, v_request.box_count) then
    raise exception '모든 박스의 CJ 규격을 선택해 주세요.';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(v_request.box_waybills, '[]')) b
      where nullif(b->>'tracking_number','') is not null and nullif(b->>'cancelled_at','') is null)
    or (jsonb_array_length(coalesce(v_request.box_waybills,'[]')) = 0 and nullif(v_request.tracking_number,'') is not null) then
    raise exception '이미 접수된 박스는 CJ 재접수에서 규격을 변경해 주세요.';
  end if;
  update public.pickup_requests set box_type_codes = p_box_type_codes, updated_at = now() where id = p_request_id;
end;
$$;
revoke all on function public.admin_set_pickup_box_types(bigint,text[]) from public, anon;
grant execute on function public.admin_set_pickup_box_types(bigint,text[]) to authenticated;

notify pgrst, 'reload schema';
commit;
-- 롤백: 이전 앱으로 복귀하기 전에 require_box_types 트리거 해제 필요.
-- 저장된 규격·운송장 기록은 보존한다. 기존 레코드에 대한 일괄 수정/삭제는 없다.
