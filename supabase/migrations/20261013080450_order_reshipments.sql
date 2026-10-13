-- 무상 재발송은 원 주문의 배송/결제/재고/정산을 변경하지 않는 별도 출고 이력이다.
-- 롤백: 앱을 이전 버전으로 되돌려도 이력은 보존. booking 건은 CJ 확인 전 해제 금지.
begin;
create table public.order_reshipments (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id),
  request_key uuid not null unique,
  claim_token uuid not null default gen_random_uuid(),
  created_by uuid not null references auth.users(id),
  reason text not null check (length(btrim(reason)) between 5 and 1000),
  items jsonb not null check (jsonb_typeof(items)='array' and jsonb_array_length(items) between 1 and 100),
  state text not null default 'claimed' check (state in ('claimed','booking','registered','failed')),
  tracking_number text,
  routing_data jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index order_reshipments_order_idx on public.order_reshipments(order_id,id desc);
create unique index order_reshipments_active_idx on public.order_reshipments(order_id) where state in ('claimed','booking');
alter table public.order_reshipments enable row level security;
revoke all on public.order_reshipments from public,anon,authenticated;
grant all on public.order_reshipments to service_role;
grant usage,select on sequence public.order_reshipments_id_seq to service_role;

create function public.admin_claim_order_reshipment(
  p_order_id bigint,p_request_key uuid,p_created_by uuid,p_reason text,p_items jsonb,p_expected_latest_id bigint default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_order orders%rowtype;
  v_row order_reshipments%rowtype;
  v_latest bigint;
  v_item jsonb;
  v_source order_items%rowtype;
  v_ids bigint[] := '{}';
  v_item_id bigint;
  v_quantity integer;
begin
  select * into v_order from orders where id=p_order_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  select * into v_row from order_reshipments where request_key=p_request_key for update;
  if found then
    if v_row.order_id<>p_order_id or v_row.reason is distinct from btrim(p_reason) or v_row.items is distinct from p_items then
      raise exception '이미 접수한 재발송 내용입니다. 이력을 새로고침해 주세요.';
    end if;
    if v_row.state='registered' then return to_jsonb(v_row); end if;
    if v_row.state='booking' then raise exception 'CJ 접수 결과 확인이 필요합니다. 운송장: %',v_row.tracking_number; end if;
    if v_row.state='claimed' and v_row.updated_at>now()-interval '10 minutes' then
      raise exception '재발송 송장 처리 중입니다. 잠시 후 이력을 확인해 주세요.';
    end if;
  end if;
  if v_order.status not in ('shipping','delivered','confirmed') or v_order.payment_status is distinct from 'paid' then
    raise exception '결제 후 발송된 주문만 무상 재발송할 수 있습니다.';
  end if;
  if p_request_key is null or p_created_by is null or length(btrim(coalesce(p_reason,''))) not between 5 and 1000 then
    raise exception '재발송 사유를 5~1000자로 입력해 주세요.';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception '재발송할 교재를 선택해 주세요.'; end if;
  if jsonb_array_length(p_items) not between 1 and 100 then raise exception '재발송할 교재를 1~100개 선택해 주세요.'; end if;
  -- 환불 처리와 같은 주문 → 품목 잠금 순서를 사용한다.
  perform id from order_items where order_id=p_order_id order by id for update;
  for v_item in select value from jsonb_array_elements(p_items) loop
    if coalesce(v_item->>'orderItemId','') !~ '^[1-9][0-9]*$'
      or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*$'
      or jsonb_typeof(v_item->'title') is distinct from 'string'
      or length(btrim(coalesce(v_item->>'title',''))) not between 1 and 200 then
      raise exception '재발송 교재명과 수량을 확인해 주세요.';
    end if;
    v_item_id:=(v_item->>'orderItemId')::bigint;
    v_quantity:=(v_item->>'quantity')::integer;
    select * into v_source from order_items where id=v_item_id and order_id=p_order_id;
    if not found or v_source.refunded_at is not null or v_quantity>v_source.quantity or v_item_id=any(v_ids) then
      raise exception '재발송 품목은 미환불 주문 교재와 주문 수량 내에서 선택해 주세요.';
    end if;
    v_ids:=array_append(v_ids,v_item_id);
  end loop;
  select max(id) into v_latest from order_reshipments where order_id=p_order_id;
  if (v_row.id is null and v_latest is distinct from p_expected_latest_id)
    or (v_row.id is not null and v_row.id is distinct from v_latest) then
    raise exception '재발송 이력이 변경되었습니다. 새로고침 후 기존 송장을 확인해 주세요.';
  end if;
  if exists(select 1 from order_reshipments where order_id=p_order_id
    and id is distinct from v_row.id and state in ('claimed','booking')) then
    raise exception '진행 중인 재발송이 있습니다. 기존 이력에서 다시 시도하거나 CJ 접수 결과를 확인해 주세요.';
  end if;
  if v_row.id is not null then
    update order_reshipments set state='claimed',claim_token=gen_random_uuid(),updated_at=now()
      where id=v_row.id returning * into v_row;
  else
    insert into order_reshipments(order_id,request_key,created_by,reason,items)
      values(p_order_id,p_request_key,p_created_by,btrim(p_reason),p_items) returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

create function public.admin_transition_order_reshipment(
  p_reshipment_id bigint,p_claim_token uuid,p_action text,p_tracking_number text default null,p_routing_data jsonb default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row order_reshipments%rowtype;
begin
  select * into v_row from order_reshipments where id=p_reshipment_id for update;
  if not found or v_row.claim_token is distinct from p_claim_token then raise exception '재발송 작업 소유권이 변경되었습니다.'; end if;
  if p_action='booking' and v_row.state='claimed' and p_tracking_number ~ '^[0-9]{12}$' then
    update order_reshipments set state='booking',tracking_number=p_tracking_number,routing_data=p_routing_data,updated_at=now() where id=v_row.id;
  elsif p_action='registered' and v_row.state in ('booking','registered') then
    update order_reshipments set state='registered',updated_at=now() where id=v_row.id;
  elsif (p_action='failed' and v_row.state='claimed') or (p_action='rejected' and v_row.state='booking') then
    update order_reshipments set state='failed',updated_at=now() where id=v_row.id;
  else raise exception 'CJ 접수 결과 확인이 필요합니다. 자동 재발급을 중단했습니다. 운송장: %',coalesce(v_row.tracking_number,'미채번');
  end if;
  select * into v_row from order_reshipments where id=p_reshipment_id;
  return to_jsonb(v_row);
end;
$$;

-- 예약 중 원 주문의 수취인/환불 대상이 바뀌지 않도록 보장한다.
create function public.guard_active_order_reshipment() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_order_id bigint;
begin
  if tg_table_name='orders' then v_order_id:=old.id; else v_order_id:=old.order_id; end if;
  if exists(select 1 from order_reshipments where order_id=v_order_id and
    (state='booking' or (state='claimed' and updated_at>now()-interval '10 minutes'))) then
    raise exception '재발송 송장 처리 중입니다. CJ 접수 결과를 확인한 뒤 변경해 주세요.';
  end if;
  return new;
end;
$$;
create trigger guard_order_reshipment_update before update of status,shipping_recipient_name,shipping_recipient_phone,
  shipping_postal_code,shipping_address_line1,shipping_address_line2,shipping_memo,refund_requested_at on public.orders
  for each row when (old.* is distinct from new.*) execute function public.guard_active_order_reshipment();
create trigger guard_order_reshipment_item_update before update of refunded_at,quantity,order_id on public.order_items
  for each row when (old.* is distinct from new.*) execute function public.guard_active_order_reshipment();
revoke all on function public.admin_claim_order_reshipment(bigint,uuid,uuid,text,jsonb,bigint),
  public.admin_transition_order_reshipment(bigint,uuid,text,text,jsonb),public.guard_active_order_reshipment() from public,anon,authenticated;
grant execute on function public.admin_claim_order_reshipment(bigint,uuid,uuid,text,jsonb,bigint),
  public.admin_transition_order_reshipment(bigint,uuid,text,text,jsonb) to service_role;
commit;
