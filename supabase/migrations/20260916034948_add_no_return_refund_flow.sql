begin;

-- 주문이 배송완료/운송장 보유 상태여도 실제로는 일부 또는 전부가 미발송·누락될 수 있다.
-- 이 사유는 운영자가 명시적으로 선택했을 때만 실물 회수 단계를 건너뛴다.
create or replace function public.admin_start_order_return(p_order_id bigint, p_item_ids bigint[], p_reason_code text, p_reason text)
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
  v_requires := case when p_reason_code='not_delivered' then false else
    v_order.status in ('shipping','delivered','confirmed','returned')
      or nullif(btrim(coalesce(to_jsonb(v_order)->>'tracking_number','')),'') is not null
      or nullif(btrim(coalesce(to_jsonb(v_order)->>'shipping_tracking_number','')),'') is not null
    end;
  insert into public.order_return_cases(order_id,reason_code,reason,requires_return,requested_by)
    -- 기존 reason_code 제약을 유지하고, 미발송·누락은 회사 책임 사유로 저장한다.
    values(p_order_id,case when p_reason_code='not_delivered' then 'seller_fault' else p_reason_code end,
      btrim(p_reason),v_requires,auth.uid()) returning id into v_id;
  insert into public.order_return_items(return_id,order_item_id) select v_id,unnest(v_ids);
  update public.orders set refund_requested_at=coalesce(refund_requested_at,now()),
    refund_request_reason=coalesce(refund_request_reason,btrim(p_reason)),refund_request_resolved_at=null
    where id=p_order_id;
  perform subook_refund_internal.log_event(v_id,'requested',jsonb_build_object(
    'item_ids',v_ids,'reason_code',p_reason_code,'requires_return',v_requires));
  return v_id;
end $$;

create or replace function public.admin_review_order_return(p_return_id uuid, p_approve boolean, p_note text, p_restock boolean default false,
  p_manual_amount integer default null, p_shipping_deduction integer default null, p_amount_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases; v_order public.orders; v_ids bigint[]; v_all boolean; v_full boolean;
  v_remaining integer; v_base integer; v_deduction integer; v_amount integer; v_auto boolean;
begin
  perform subook_refund_internal.assert_admin();
  select * into v_case from public.order_return_cases where id=p_return_id;
  if not found then raise exception '반품을 찾을 수 없습니다.'; end if;
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
  -- 미발송·배송 누락의 첫 전체 환불은 실제 결제잔액 전액을 자동 승인한다.
  v_auto := v_full and v_case.reason_code in ('buyer_remorse','seller_fault','not_delivered') and p_manual_amount is null;
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
    if (v_case.reason_code in ('seller_fault','not_delivered') or not v_case.requires_return) and v_deduction<>0 then
      raise exception '하자·오배송 또는 회수 불필요 취소에는 반품 배송비를 차감할 수 없습니다.';
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

-- 회수 없는 취소는 접수와 금액 승인을 한 트랜잭션에서 끝낸다. 실제 카드 취소는 기존
-- payment-cancel API가 승인 스냅샷을 다시 검증한 뒤 실행하므로 PG 멱등·대사 보호를 그대로 쓴다.
create function public.admin_prepare_no_return_refund(
  p_order_id bigint,
  p_item_ids bigint[],
  p_reason text,
  p_restock boolean default false,
  p_manual_amount integer default null,
  p_amount_note text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_result jsonb;
begin
  perform subook_refund_internal.assert_admin();
  if length(btrim(coalesce(p_reason,''))) < 5 then
    raise exception '미발송·배송 누락 사유를 5자 이상 입력해주세요.';
  end if;
  v_id := public.admin_start_order_return(p_order_id,p_item_ids,'not_delivered',p_reason);
  v_result := public.admin_review_order_return(
    v_id,true,p_reason,p_restock,p_manual_amount,
    case when p_manual_amount is null then null else 0 end,
    p_amount_note
  );
  return v_result || jsonb_build_object('return_id',v_id,'requires_return',false);
end $$;

revoke all on function public.admin_prepare_no_return_refund(bigint,bigint[],text,boolean,integer,text) from public,anon;
grant execute on function public.admin_prepare_no_return_refund(bigint,bigint[],text,boolean,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;
