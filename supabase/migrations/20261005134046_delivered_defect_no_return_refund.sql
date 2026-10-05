-- 배송된 하자 교재의 회수 면제 환불. 기존 금액 승인·PG 대사·정산 처리를 그대로 사용한다.
-- 기존 행 보정 없음. 기존 관리자 SELECT RLS와 RPC 전용 쓰기 권한을 유지한다.
-- 롤백: UI 진입점을 제거하되 진행 중인 환불은 기존 토큰으로 대사·완료한다.
-- 회수 면제 이력과 재판매 제외 기록은 삭제하지 않는다.
begin;

alter table public.order_return_cases
  add column return_waived boolean not null default false,
  add constraint order_return_waived_no_restock check (
    not return_waived or (not requires_return and not restock and reason_code='seller_fault')
  );

create function public.admin_prepare_delivered_no_return_refund(
  p_order_id bigint, p_item_ids bigint[], p_reason text,
  p_manual_amount integer default null, p_amount_note text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_result jsonb; v_requires boolean;
begin
  perform subook_refund_internal.assert_admin();
  if length(btrim(coalesce(p_reason,'')))<5 then
    raise exception '하자 내용과 회수하지 않는 사유를 5자 이상 기록해주세요.';
  end if;
  -- 회사 책임 접수와 회수 면제·승인은 원자적으로 저장한다. 실패하면 접수도 롤백된다.
  v_id := public.admin_start_order_return(p_order_id,p_item_ids,'seller_fault',p_reason);
  select requires_return into v_requires from public.order_return_cases where id=v_id;
  if not v_requires then
    raise exception '배송중·배송완료·구매확정 또는 발송 기록이 있는 주문만 배송 후 회수 없는 환불을 처리할 수 있습니다.';
  end if;
  update public.order_return_cases set requires_return=false,return_waived=true,restock=false where id=v_id;
  perform subook_refund_internal.log_event(v_id,'return_waived',jsonb_build_object(
    'reason',btrim(p_reason),'requires_return',false,'restock',false));
  v_result := public.admin_review_order_return(v_id,true,p_reason,false,p_manual_amount,
    case when p_manual_amount is null then null else 0 end,p_amount_note);
  return v_result || jsonb_build_object('return_id',v_id,'requires_return',false,'return_waived',true);
end $$;

-- PG 성공 후 기존 완료 RPC의 동일 트랜잭션에서만 재판매 제외를 확정한다.
-- 기존 미지급 정산 취소·지급완료 회수필요 기록은 내부 환불 RPC가 품목별로 처리한다.
create or replace function public.admin_complete_return_refund(p_return_id uuid,p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_case public.order_return_cases; v_ids bigint[]; v_result jsonb; v_count integer;
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
  if v_case.return_waived then
    -- 동일 실물이 다른 활성 주문에 연결되어 있으면 임의로 폐기하지 않는다.
    if exists (
      select 1 from public.order_return_items ri
      join public.order_items oi on oi.id=ri.order_item_id
      join public.order_items other_item on other_item.book_id=oi.book_id and other_item.id<>oi.id
      join public.orders other_order on other_order.id=other_item.order_id
      where ri.return_id=p_return_id and other_item.refunded_at is null
        and other_order.status not in ('cancelled','refunded')
    ) then raise exception '회수 면제 교재가 다른 활성 주문에 연결되어 있어 재고 확인이 필요합니다.'; end if;
    update public.books b set status='discarded',is_public=false
      where b.id in (
        select oi.book_id from public.order_return_items ri
        join public.order_items oi on oi.id=ri.order_item_id
        where ri.return_id=p_return_id and oi.refunded_at is not null
      );
    get diagnostics v_count = row_count;
    update public.order_items oi set restock_held_at=null
      where oi.id=any(v_ids) and oi.refunded_at is not null;
    v_result := v_result || jsonb_build_object('held_books',0,'discarded_books',v_count,'return_waived',true);
    perform subook_refund_internal.log_event(p_return_id,'waived_inventory_excluded',jsonb_build_object('book_count',v_count));
  end if;
  update public.order_return_cases set status='refunded',completed_at=now(),result=v_result,failure_note=null where id=p_return_id;
  update public.orders set refund_request_resolved_at=now() where id=v_case.order_id;
  perform subook_refund_internal.log_event(p_return_id,'refunded',v_result);
  return v_result;
end $$;

-- 정산 생성은 환불 접수와 동일 주문 잠금을 사용한다. 진행 중에는 생성도 보류한다.
-- 현재 수수료 정책·비회원·박스비 계산 및 refunded_at 제외 본문과 권한을 보존한다.
do $migration$
declare v_definition text;
begin
  v_definition := pg_get_functiondef('public.create_settlements_for_order(bigint)'::regprocedure);
  if position('and confirmed_at is not null;' in v_definition)=0
    or position('  for v_item in' in v_definition)=0
    or position('oi.refunded_at is null' in v_definition)=0 then
    raise exception '정산 생성 함수가 예상 정의와 다릅니다. 자동 변경을 중단합니다.';
  end if;
  v_definition := replace(v_definition,'and confirmed_at is not null;','and confirmed_at is not null for update;');
  v_definition := replace(v_definition,'  for v_item in',
    E'  if (v_order.refund_requested_at is not null and v_order.refund_request_resolved_at is null)\n'
    || E'    or exists(select 1 from public.order_return_cases where order_id=p_order_id and status not in (''refunded'',''cancelled'')) then\n'
    || E'    return jsonb_build_object(''success'',false,''reason'',''refund_on_hold'');\n  end if;\n\n  for v_item in');
  execute v_definition;
end $migration$;

revoke all on function public.admin_prepare_delivered_no_return_refund(bigint,bigint[],text,integer,text) from public,anon;
grant execute on function public.admin_prepare_delivered_no_return_refund(bigint,bigint[],text,integer,text) to authenticated;

notify pgrst, 'reload schema';
commit;
