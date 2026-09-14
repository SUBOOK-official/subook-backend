-- 반품 도착·검수 후 환불. 기존 재고/정산/쿠폰/포인트 처리는 본문을 보존해 재사용한다.
-- 운영 적용 순서: 새 admin API/UI → DB → public UI. DB 준비 전 새 API는 PG 호출을 차단한다.
-- 진행 중인 환불을 마친 전환 시간에 적용한다. 구 API가 남은 상태에서 DB부터 적용하지 않는다.
-- 롤백: 새 반품을 먼저 종결·대사한 뒤 별도 migration으로 공개 래퍼를 되돌린다.
-- 반품 이력 테이블을 삭제하거나 미확인 PG 요청을 다시 실행하는 롤백은 금지한다.
begin;

create schema if not exists subook_refund_internal;
revoke all on schema subook_refund_internal from public, anon, authenticated;

create table public.order_return_cases (
  id uuid primary key default gen_random_uuid(),
  order_id bigint not null references public.orders(id),
  status text not null default 'requested' check (status in
    ('requested','received','review_hold','approved','processing','attention','refunded','cancelled')),
  reason_code text not null check (reason_code in ('buyer_remorse','seller_fault','other')),
  reason text not null check (length(btrim(reason)) >= 5),
  requires_return boolean not null,
  requested_at timestamptz not null default now(),
  requested_by uuid,
  received_at timestamptz,
  inspected_at timestamptz,
  inspected_by uuid,
  inspection_note text,
  restock boolean not null default false,
  amount_mode text check (amount_mode in ('automatic','manual')),
  refund_base integer,
  shipping_deduction integer check (shipping_deduction between 0 and 6000),
  refund_amount integer check (refund_amount > 0),
  amount_note text,
  refunded_before integer,
  remaining_before integer,
  policy_version text not null default 'return-2026-09-13',
  claim_token uuid,
  claimed_at timestamptz,
  transfer_reference text,
  failure_note text,
  completed_at timestamptz,
  result jsonb
);
-- 한 주문의 환불을 직렬화한다. 여러 차례의 일부 반품은 이전 건 종결 후 접수한다.
create unique index order_return_one_active on public.order_return_cases(order_id)
  where status not in ('refunded','cancelled');
create index order_return_cases_order_history on public.order_return_cases(order_id, requested_at desc);

create table public.order_return_items (
  return_id uuid not null references public.order_return_cases(id),
  order_item_id bigint not null references public.order_items(id),
  received_at timestamptz,
  received_by uuid,
  primary key(return_id, order_item_id)
);
create table public.order_return_events (
  id bigint generated always as identity primary key,
  return_id uuid not null references public.order_return_cases(id),
  action text not null,
  actor_id uuid,
  created_at timestamptz not null default now(),
  detail jsonb not null default '{}'::jsonb
);
alter table public.order_return_cases enable row level security;
alter table public.order_return_items enable row level security;
alter table public.order_return_events enable row level security;
revoke all on public.order_return_cases, public.order_return_items, public.order_return_events from anon, authenticated;
grant select on public.order_return_cases, public.order_return_items, public.order_return_events to authenticated;
create policy return_cases_admin_read on public.order_return_cases for select to authenticated using (public.is_admin_user());
create policy return_items_admin_read on public.order_return_items for select to authenticated using (public.is_admin_user());
create policy return_events_admin_read on public.order_return_events for select to authenticated using (public.is_admin_user());

-- 기존 함수의 본문과 종속 트리거를 보존하며 API 비노출 스키마로 옮긴다.
alter function public.admin_refund_order_items(bigint,bigint[],integer,text,boolean,boolean,boolean) set schema subook_refund_internal;
alter function public.admin_refund_order(bigint,text,boolean,boolean) set schema subook_refund_internal;
alter function public.admin_resolve_refund_request(bigint) set schema subook_refund_internal;
revoke all on all functions in schema subook_refund_internal from public, anon, authenticated, service_role;

create function subook_refund_internal.assert_admin() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.is_admin_user(), false) then raise exception 'Admin access required'; end if;
end $$;

create function subook_refund_internal.log_event(p_id uuid, p_action text, p_detail jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.order_return_events(return_id,action,actor_id,detail)
    values(p_id,p_action,auth.uid(),p_detail);
$$;

create function public.admin_get_order_returns(p_order_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_result jsonb;
begin
  perform subook_refund_internal.assert_admin();
  select coalesce(jsonb_agg((to_jsonb(r) - 'claim_token') || jsonb_build_object('items',
    (select coalesce(jsonb_agg(jsonb_build_object('id',i.order_item_id,'title',oi.title,
      'received_at',i.received_at,'total_price',oi.total_price) order by i.order_item_id),'[]'::jsonb)
      from public.order_return_items i join public.order_items oi on oi.id=i.order_item_id where i.return_id=r.id))
    order by r.requested_at desc),'[]'::jsonb) into v_result
    from public.order_return_cases r where r.order_id=p_order_id;
  return v_result;
end $$;

-- 구매자 공개용 결과는 내부 검수 메모/관리자/계좌/실행 토큰 없이 본인 주문만 반환한다.
create function public.get_my_order_return_progress() returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('order_id',r.order_id,'status',r.status,
    'requested_at',r.requested_at,'received_at',r.received_at,
    'refund_amount',r.refund_amount,'shipping_deduction',r.shipping_deduction)
    order by r.requested_at desc),'[]'::jsonb)
  from public.order_return_cases r join public.orders o on o.id=r.order_id
  where o.user_id=auth.uid();
$$;

create function public.admin_start_order_return(p_order_id bigint, p_item_ids bigint[], p_reason_code text, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_ids bigint[]; v_id uuid; v_requires boolean;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_order from public.orders where id=p_order_id for update;
  if not found or v_order.status in ('pending','cancelled','refunded') then
    raise exception '결제된 미환불 주문만 처리할 수 있습니다.';
  end if;
  select array_agg(distinct x order by x) into v_ids from unnest(p_item_ids) x where x is not null;
  if coalesce(cardinality(v_ids),0)=0 or cardinality(v_ids) <> (
    select count(*) from public.order_items where order_id=p_order_id and id=any(v_ids) and refunded_at is null
  ) then raise exception '환불할 미환불 품목을 정확히 선택해주세요.'; end if;
  if exists(select 1 from public.order_return_cases where order_id=p_order_id and status not in ('refunded','cancelled')) then
    raise exception '진행 중인 반품이 있습니다. 기존 반품을 먼저 처리해주세요.';
  end if;
  v_requires := v_order.status in ('shipping','delivered','confirmed','returned')
    or nullif(btrim(coalesce(to_jsonb(v_order)->>'tracking_number','')),'') is not null
    or nullif(btrim(coalesce(to_jsonb(v_order)->>'shipping_tracking_number','')),'') is not null;
  insert into public.order_return_cases(order_id,reason_code,reason,requires_return,requested_by)
    values(p_order_id,p_reason_code,btrim(p_reason),v_requires,auth.uid()) returning id into v_id;
  insert into public.order_return_items(return_id,order_item_id) select v_id,unnest(v_ids);
  update public.orders set refund_requested_at=coalesce(refund_requested_at,now()),
    refund_request_reason=coalesce(refund_request_reason,btrim(p_reason)),refund_request_resolved_at=null
    where id=p_order_id;
  perform subook_refund_internal.log_event(v_id,'requested',jsonb_build_object('item_ids',v_ids,'reason_code',p_reason_code));
  return v_id;
end $$;

create function public.admin_receive_order_return(p_return_id uuid, p_item_ids bigint[])
returns void language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id for update;
  if not found or v_case.status not in ('requested','received','review_hold') then raise exception '도착 확인이 가능한 반품이 아닙니다.'; end if;
  if coalesce(cardinality(p_item_ids),0)=0 or exists(select 1 from unnest(p_item_ids) x where x is null or not exists(
    select 1 from public.order_return_items where return_id=p_return_id and order_item_id=x)) then
    raise exception '이 반품에 속한 도착 품목을 선택해주세요.';
  end if;
  update public.order_return_items set received_at=coalesce(received_at,now()),received_by=coalesce(received_by,auth.uid())
    where return_id=p_return_id and order_item_id=any(p_item_ids);
  -- 첫 실물 도착 시각 보존: 나머지 책의 도착이나 재검수로 기한이 뒤로 밀리지 않는다.
  update public.order_return_cases set received_at=coalesce(received_at,now()),
    status=case when not exists(select 1 from public.order_return_items where return_id=p_return_id and received_at is null)
      then 'received' else status end where id=p_return_id;
  perform subook_refund_internal.log_event(p_return_id,'received',jsonb_build_object('item_ids',p_item_ids));
end $$;

create function public.admin_review_order_return(p_return_id uuid, p_approve boolean, p_note text, p_restock boolean default false,
  p_manual_amount integer default null, p_shipping_deduction integer default null, p_amount_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases; v_order public.orders; v_ids bigint[]; v_all boolean; v_full boolean;
  v_remaining integer; v_base integer; v_deduction integer; v_amount integer; v_auto boolean;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id;
  if not found then raise exception '반품을 찾을 수 없습니다.'; end if;
  -- 환불 실행과 동일하게 order → return 순서로 잠근다.
  select * into v_order from public.orders where id=v_case.order_id for update;
  select * into v_case from public.order_return_cases where id=p_return_id for update;
  if v_case.status not in ('requested','received','review_hold') then raise exception '검수 가능한 반품이 아닙니다.'; end if;
  if length(btrim(coalesce(p_note,''))) < 5 then raise exception '검수 결과를 5자 이상 기록해주세요.'; end if;
  if p_approve is not true then
    update public.order_return_cases set status='review_hold',inspection_note=btrim(p_note) where id=p_return_id;
    perform subook_refund_internal.log_event(p_return_id,'review_hold',jsonb_build_object('note',p_note));
    return jsonb_build_object('status','review_hold');
  end if;
  if v_case.requires_return and exists(select 1 from public.order_return_items where return_id=p_return_id and received_at is null) then
    raise exception '모든 반품 교재의 도착을 확인한 뒤 검수를 승인해주세요.';
  end if;
  select array_agg(order_item_id order by order_item_id) into v_ids from public.order_return_items where return_id=p_return_id;
  if exists(select 1 from public.order_items where id=any(v_ids) and refunded_at is not null) then raise exception '이미 환불된 품목이 있습니다.'; end if;
  v_remaining := coalesce(v_order.total_amount,0)-coalesce(v_order.refunded_amount,0);
  v_all := not exists(select 1 from public.order_items where order_id=v_order.id and refunded_at is null and not(id=any(v_ids)));
  v_full := v_all and coalesce(v_order.refunded_amount,0)=0 and not exists(
    select 1 from public.order_items where order_id=v_order.id and refunded_at is not null);
  -- 자동 계산은 첫 전체 환불에 한정. 누적/일부 반품의 할인·기차감 배송료는 명시 검토한다.
  v_auto := v_full and v_case.reason_code in ('buyer_remorse','seller_fault') and p_manual_amount is null;
  if v_auto then
    v_base := v_remaining;
    v_deduction := case when v_case.requires_return and v_case.reason_code='buyer_remorse' then 6000 else 0 end;
    v_amount := v_base-v_deduction;
  else
    if p_manual_amount is null or p_shipping_deduction is null or length(btrim(coalesce(p_amount_note,'')))<5 then
      raise exception '일부 반품·기타 사유·금액 조정은 최종 환불액, 배송비 차감액, 계산 근거를 입력해주세요.';
    end if;
    v_amount := p_manual_amount; v_deduction := p_shipping_deduction; v_base := v_amount+v_deduction;
    if v_deduction not between 0 and 6000 then raise exception '배송비 차감액은 0~6,000원이어야 합니다.'; end if;
    if (v_case.reason_code='seller_fault' or not v_case.requires_return) and v_deduction<>0 then
      raise exception '하자·오배송 또는 발송 전 취소에는 반품 배송비를 차감할 수 없습니다.';
    end if;
  end if;
  if v_amount<=0 then raise exception '배송비 차감 후 환불액이 0원 이하입니다. 별도 수납·종결 방법을 확인해주세요.'; end if;
  if v_amount>v_remaining or v_base>v_remaining then raise exception '환불액과 배송비 차감액 합계가 남은 결제금액을 초과합니다.'; end if;
  update public.order_return_cases set status='approved',inspected_at=now(),inspected_by=auth.uid(),
    inspection_note=btrim(p_note),restock=coalesce(p_restock,false),amount_mode=case when v_auto then 'automatic' else 'manual' end,
    refund_base=v_base,shipping_deduction=v_deduction,refund_amount=v_amount,amount_note=nullif(btrim(p_amount_note),''),
    refunded_before=coalesce(v_order.refunded_amount,0),remaining_before=v_remaining where id=p_return_id;
  perform subook_refund_internal.log_event(p_return_id,'approved',jsonb_build_object('note',p_note,'restock',p_restock,
    'refund_base',v_base,'shipping_deduction',v_deduction,'refund_amount',v_amount,'amount_note',p_amount_note));
  return jsonb_build_object('status','approved','refund_amount',v_amount,'shipping_deduction',v_deduction);
end $$;

create function public.admin_cancel_order_return(p_return_id uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id;
  if not found then raise exception '반품을 찾을 수 없습니다.'; end if;
  perform 1 from public.orders where id=v_case.order_id for update;
  select * into v_case from public.order_return_cases where id=p_return_id for update;
  if v_case.status not in ('requested','received','review_hold','approved') then raise exception '이미 환불을 실행한 반품은 종결할 수 없습니다. 결제 결과를 먼저 확인해주세요.'; end if;
  if length(btrim(coalesce(p_note,'')))<5 then raise exception '종결 사유를 5자 이상 입력해주세요.'; end if;
  update public.order_return_cases set status='cancelled',completed_at=now() where id=p_return_id;
  update public.orders set refund_request_resolved_at=now() where id=v_case.order_id;
  perform subook_refund_internal.log_event(p_return_id,'cancelled',jsonb_build_object('note',p_note));
end $$;

-- 새 검수 흐름을 우회하는 기존 API/RPC 차단. 발송 전 기존 처리만 호환한다.
create function public.admin_resolve_refund_request(p_order_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform subook_refund_internal.assert_admin();
  perform 1 from public.orders where id=p_order_id for update;
  if exists(select 1 from public.order_return_cases where order_id=p_order_id and status not in ('refunded','cancelled')) then
    raise exception '진행 중인 반품이 있습니다. 반품·환불 화면에서 사유를 기록하고 종결해주세요.';
  end if;
  return subook_refund_internal.admin_resolve_refund_request(p_order_id);
end $$;
revoke all on function public.admin_resolve_refund_request(bigint) from public,anon;
grant execute on function public.admin_resolve_refund_request(bigint) to authenticated;

create function public.admin_assert_legacy_refund_allowed(p_order_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  if v_order.status not in ('paid','preparing') or
    nullif(btrim(coalesce(to_jsonb(v_order)->>'tracking_number','')),'') is not null or
    nullif(btrim(coalesce(to_jsonb(v_order)->>'shipping_tracking_number','')),'') is not null or
    exists(select 1 from public.order_return_cases where order_id=p_order_id and status not in ('refunded','cancelled')) then
    raise exception 'RETURN_INSPECTION_REQUIRED: 새 반품·환불 화면에서 도착 확인과 검수 후 환불해주세요.';
  end if;
end $$;
create function public.admin_refund_order_items(p_order_id bigint,p_order_item_ids bigint[],p_refund_amount integer default null,
  p_reason text default null,p_acknowledge_recovery boolean default false,p_validate_only boolean default false,p_restock boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_assert_legacy_refund_allowed(p_order_id);
  return subook_refund_internal.admin_refund_order_items(p_order_id,p_order_item_ids,p_refund_amount,p_reason,p_acknowledge_recovery,p_validate_only,p_restock);
end $$;
create function public.admin_refund_order(p_order_id bigint,p_reason text default null,p_acknowledge_recovery boolean default false,p_restock boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.admin_assert_legacy_refund_allowed(p_order_id);
  return subook_refund_internal.admin_refund_order(p_order_id,p_reason,p_acknowledge_recovery,p_restock);
end $$;

create function public.admin_claim_return_refund(p_return_id uuid,p_transfer_reference text default null,p_acknowledge_recovery boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases; v_order public.orders; v_ids bigint[]; v_validation jsonb;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id;
  if not found then raise exception '반품을 찾을 수 없습니다.'; end if;
  select * into v_order from public.orders where id=v_case.order_id for update;
  select * into v_case from public.order_return_cases where id=p_return_id for update;
  if v_case.status <> 'approved' then raise exception '검수·금액 승인 후 한 번만 환불을 실행할 수 있습니다. 처리 중인 건은 결제 결과를 확인해주세요.'; end if;
  if v_case.inspected_at is null or (v_case.requires_return and exists(select 1 from public.order_return_items where return_id=p_return_id and received_at is null)) then
    raise exception '도착·검수 승인 기록이 없습니다.';
  end if;
  if coalesce(v_order.refunded_amount,0)<>v_case.refunded_before or
    coalesce(v_order.total_amount,0)-coalesce(v_order.refunded_amount,0)<>v_case.remaining_before then
    raise exception '승인 후 주문 환불액이 변경되었습니다. 금액을 다시 확인해주세요.';
  end if;
  if v_order.payment_key is null and (v_order.payment_method<>'bank_transfer' or length(btrim(coalesce(p_transfer_reference,'')))<5) then
    raise exception '무통장 환불은 직접 송금한 뒤 송금일시·확인번호를 입력해주세요. 카드 결제키 누락은 운영 확인이 필요합니다.';
  end if;
  select array_agg(order_item_id order by order_item_id) into v_ids from public.order_return_items where return_id=p_return_id;
  v_validation := subook_refund_internal.admin_refund_order_items(v_order.id,v_ids,v_case.refund_amount,v_case.reason,p_acknowledge_recovery,true,v_case.restock);
  update public.order_return_cases set status='processing',claim_token=gen_random_uuid(),claimed_at=now(),
    transfer_reference=nullif(btrim(p_transfer_reference),''),failure_note=null where id=p_return_id returning * into v_case;
  perform subook_refund_internal.log_event(p_return_id,'refund_started',jsonb_build_object('refund_amount',v_case.refund_amount,'recovery_ack',p_acknowledge_recovery));
  return jsonb_build_object('return_id',v_case.id,'token',v_case.claim_token,'claimed_at',v_case.claimed_at,
    'whole_order',v_validation->'order_fully_refunded','order',jsonb_build_object(
    'id',v_order.id,'order_number',v_order.order_number,'payment_key',v_order.payment_key,'pg_provider',v_order.pg_provider,
    'payment_method',v_order.payment_method,'total_amount',v_order.total_amount,'refunded_amount',v_case.refunded_before),
    'item_ids',v_ids,'refund_amount',v_case.refund_amount,'reason',v_case.reason,'remaining_before',v_case.remaining_before);
end $$;

create function public.admin_flag_return_refund(p_return_id uuid,p_token uuid,p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform subook_refund_internal.assert_admin();
  update public.order_return_cases set status='attention',failure_note=left(p_note,1000)
    where id=p_return_id and claim_token=p_token and status='processing';
  if found then perform subook_refund_internal.log_event(p_return_id,'refund_attention',jsonb_build_object('note',left(p_note,1000))); end if;
end $$;

-- 응답 유실 시 취소를 다시 요청하지 않고 PG 거래내역을 대조하는 데 필요한 고정 스냅샷.
create function public.admin_get_return_refund_attempt(p_return_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases; v_order public.orders;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id;
  if not found or v_case.status not in ('processing','attention') then raise exception '결제 결과를 확인할 반품이 아닙니다.'; end if;
  if v_case.claimed_at>now()-interval '60 seconds' then raise exception '환불 요청 결과를 기다리는 중입니다. 1분 후 다시 확인해주세요.'; end if;
  select * into v_order from public.orders where id=v_case.order_id;
  return jsonb_build_object('return_id',v_case.id,'token',v_case.claim_token,'claimed_at',v_case.claimed_at,
    'whole_order',not exists(select 1 from public.order_items oi where oi.order_id=v_case.order_id and oi.refunded_at is null
      and not exists(select 1 from public.order_return_items ri where ri.return_id=p_return_id and ri.order_item_id=oi.id)),
    'order',jsonb_build_object('id',v_order.id,'order_number',v_order.order_number,'payment_key',v_order.payment_key,
    'pg_provider',v_order.pg_provider,'payment_method',v_order.payment_method,'total_amount',v_order.total_amount,'refunded_amount',v_case.refunded_before),
    'item_ids',(select jsonb_agg(order_item_id order by order_item_id) from public.order_return_items where return_id=p_return_id),
    'refund_amount',v_case.refund_amount,'remaining_before',v_case.remaining_before,'reason',v_case.reason);
end $$;

create function public.admin_complete_return_refund(p_return_id uuid,p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases; v_ids bigint[]; v_result jsonb;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id;
  if not found then raise exception '반품을 찾을 수 없습니다.'; end if;
  perform 1 from public.orders where id=v_case.order_id for update;
  select * into v_case from public.order_return_cases where id=p_return_id for update;
  if p_token is null or v_case.claim_token is distinct from p_token then raise exception '환불 실행 토큰이 일치하지 않습니다.'; end if;
  if v_case.status='refunded' then return v_case.result || jsonb_build_object('already_completed',true); end if;
  if v_case.status not in ('processing','attention') then raise exception '실행 중인 환불이 아닙니다.'; end if;
  select array_agg(order_item_id order by order_item_id) into v_ids from public.order_return_items where return_id=p_return_id;
  -- claim 단계에서 손실 확인 검증을 마쳤다. PG 성공 이후 확인 모달을 다시 요구하지 않는다.
  v_result := subook_refund_internal.admin_refund_order_items(v_case.order_id,v_ids,v_case.refund_amount,v_case.reason,true,false,v_case.restock);
  update public.order_return_cases set status='refunded',completed_at=now(),result=v_result,failure_note=null where id=p_return_id;
  update public.orders set refund_request_resolved_at=now() where id=v_case.order_id;
  perform subook_refund_internal.log_event(p_return_id,'refunded',v_result);
  return v_result;
end $$;

-- 진행 중인 반품이 있으면 다른 관리 화면에서도 확정·신청 해소를 우회할 수 없다.
create function subook_refund_internal.hold_order_during_return() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.order_return_cases where order_id=new.id and status not in ('refunded','cancelled')) then
    if new.status='confirmed' and old.status<>'confirmed' then raise exception '진행 중인 반품이 있어 구매확정할 수 없습니다.'; end if;
    new.refund_request_resolved_at:=null;
  end if;
  return new;
end $$;
create trigger hold_order_during_return before update on public.orders
  for each row execute function subook_refund_internal.hold_order_during_return();

revoke all on all functions in schema subook_refund_internal from public, anon, authenticated, service_role;
-- 새 공개 RPC는 관리자 확인 또는 본인 주문 필터를 함수 안에서 강제한다.
revoke all on function public.admin_get_order_returns(bigint),public.get_my_order_return_progress(),
  public.admin_start_order_return(bigint,bigint[],text,text),public.admin_receive_order_return(uuid,bigint[]),
  public.admin_review_order_return(uuid,boolean,text,boolean,integer,integer,text),public.admin_cancel_order_return(uuid,text),
  public.admin_assert_legacy_refund_allowed(bigint),public.admin_claim_return_refund(uuid,text,boolean),
  public.admin_flag_return_refund(uuid,uuid,text),public.admin_get_return_refund_attempt(uuid),public.admin_complete_return_refund(uuid,uuid),
  public.admin_refund_order_items(bigint,bigint[],integer,text,boolean,boolean,boolean),public.admin_refund_order(bigint,text,boolean,boolean)
  from public,anon;
grant execute on function public.admin_get_order_returns(bigint),public.get_my_order_return_progress(),
  public.admin_start_order_return(bigint,bigint[],text,text),public.admin_receive_order_return(uuid,bigint[]),
  public.admin_review_order_return(uuid,boolean,text,boolean,integer,integer,text),public.admin_cancel_order_return(uuid,text),
  public.admin_assert_legacy_refund_allowed(bigint),public.admin_claim_return_refund(uuid,text,boolean),
  public.admin_flag_return_refund(uuid,uuid,text),public.admin_get_return_refund_attempt(uuid),public.admin_complete_return_refund(uuid,uuid),
  public.admin_refund_order_items(bigint,bigint[],integer,text,boolean,boolean,boolean),public.admin_refund_order(bigint,text,boolean,boolean)
  to authenticated;
notify pgrst, 'reload schema';
commit;
