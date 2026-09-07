-- 주문/결제는 유지하고 실제 발송 단위만 묶는다. CJ 예약 직전 번호를 영속화한다.
-- 실패가 확실한 채번 전 단계만 재시도. CJ 응답 유실은 자동 재발급하지 않는다.
-- 롤백: 이전 앱으로 돌아가기 전에 claimed/booking 그룹을 운영 확인할 것.
-- 기존 데이터/정책 변경 없음. 새 테이블은 service_role 전용이다.
begin;

create table public.order_delivery_groups (
  id uuid primary key default gen_random_uuid(),
  claim_token uuid not null default gen_random_uuid(),
  state text not null default 'claimed' check (state in ('claimed','booking','registered','failed')),
  tracking_number text,
  routing_data jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.order_delivery_group_members (
  order_id bigint primary key references public.orders(id),
  group_id uuid not null references public.order_delivery_groups(id)
);
create index order_delivery_group_members_group_idx on public.order_delivery_group_members(group_id);
alter table public.order_delivery_groups enable row level security;
alter table public.order_delivery_group_members enable row level security;
revoke all on public.order_delivery_groups, public.order_delivery_group_members from anon, authenticated;
grant all on public.order_delivery_groups, public.order_delivery_group_members to service_role;

create function public.delivery_match_key(p_order public.orders) returns text
language sql immutable set search_path = public as $$
  select case
    -- 비회원은 구매자 식별자가 없으므로 이름/주소만으로 합치지 않는다.
    when p_order.user_id is null
      or btrim(coalesce(p_order.shipping_recipient_name,'')) = ''
      or length(regexp_replace(coalesce(p_order.shipping_recipient_phone,''),'[^0-9]','','g')) < 8
      or btrim(coalesce(p_order.shipping_postal_code,'')) = ''
      or btrim(coalesce(p_order.shipping_address_line1,'')) = ''
    then 'single:' || p_order.id::text
    else jsonb_build_array(p_order.user_id,
      regexp_replace(btrim(p_order.shipping_recipient_name),'[[:space:]]+',' ','g'),
      regexp_replace(p_order.shipping_recipient_phone,'[^0-9]','','g'),
      btrim(p_order.shipping_postal_code),
      regexp_replace(btrim(p_order.shipping_address_line1),'[[:space:]]+',' ','g'),
      regexp_replace(btrim(coalesce(p_order.shipping_address_line2,'')),'[[:space:]]+',' ','g')
    )::text end;
$$;

create function public.delivery_order_ready(p_order public.orders) returns boolean
language sql immutable set search_path = public as $$
  select p_order.status in ('preparing','paid')
    and nullif(btrim(p_order.tracking_number),'') is null
    and (p_order.refund_requested_at is null or p_order.refund_request_resolved_at is not null);
$$;

-- 선택하지 않은 페이지의 동일 구매자 주문도 미리보기에서 함께 보여준다.
create function public.admin_plan_order_deliveries(p_order_ids bigint[]) returns jsonb
language sql stable security definer set search_path = public as $$
  with keys as (
    select distinct delivery_match_key(o) as k from orders o
    where o.id = any(p_order_ids) and delivery_order_ready(o)
  ), grouped as (
    select array_agg(o.id order by o.id) as ids from orders o
    join keys on keys.k = delivery_match_key(o)
    where delivery_order_ready(o)
      and exists(select 1 from order_items i where i.order_id=o.id and i.refunded_at is null)
    group by keys.k
  )
  select coalesce(jsonb_agg(to_jsonb(ids) order by ids[1]),'[]'::jsonb) from grouped;
$$;

create function public.admin_claim_order_delivery(p_order_ids bigint[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ids bigint[];
  v_group order_delivery_groups%rowtype;
  v_count integer;
  v_keys integer;
begin
  select array_agg(distinct x order by x) into v_ids from unnest(p_order_ids) x;
  if coalesce(cardinality(v_ids),0) = 0 or cardinality(v_ids) > 30 then
    raise exception '한 박스에는 최대 30개 주문까지 처리할 수 있습니다.';
  end if;
  -- 같은 주문을 포함하는 동시 요청을 DB에서 직렬화한다.
  perform id from orders where id = any(v_ids) order by id for update;
  perform id from order_items where order_id = any(v_ids) order by id for update;
  -- 채번/예약 전 종료된 작업만 회수. 예약을 시작한 작업은 자동 회수 금지.
  update order_delivery_groups g set state='failed',updated_at=now()
  where g.state='claimed' and g.updated_at < now()-interval '10 minutes'
    and exists (select 1 from order_delivery_group_members m where m.group_id=g.id and m.order_id=any(v_ids));
  delete from order_delivery_group_members m using order_delivery_groups g
  where m.group_id=g.id and g.state='failed' and m.order_id=any(v_ids);

  select g.* into v_group from order_delivery_groups g
  join order_delivery_group_members m on m.group_id=g.id where m.order_id=any(v_ids) limit 1;
  if found then
    if v_group.state='registered' and not exists (
      select 1 from unnest(v_ids) x where not exists (
        select 1 from order_delivery_group_members m where m.order_id=x and m.group_id=v_group.id
      )
    ) then return to_jsonb(v_group); end if;
    raise exception '송장 처리 중이거나 CJ 접수 결과 확인이 필요합니다. 중복 발급을 막기 위해 중단했습니다. 운송장: %',coalesce(v_group.tracking_number,'미채번');
  end if;
  select count(*),count(distinct delivery_match_key(o)) into v_count,v_keys
  from orders o where id=any(v_ids) and delivery_order_ready(o)
    and exists(select 1 from order_items i where i.order_id=o.id and i.refunded_at is null);
  if v_count <> cardinality(v_ids) or v_keys <> 1 then
    raise exception '주문 상태 또는 배송지가 변경되었습니다. 송장 출력 대상을 다시 확인해 주세요.';
  end if;
  insert into order_delivery_groups default values returning * into v_group;
  insert into order_delivery_group_members(order_id,group_id) select unnest(v_ids),v_group.id;
  return to_jsonb(v_group);
end;
$$;

create function public.admin_transition_order_delivery(
  p_group_id uuid,p_claim_token uuid,p_action text,p_tracking_number text default null,p_routing_data jsonb default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_group order_delivery_groups%rowtype;
begin
  -- claim과 동일한 잠금 순서(orders → group)로 교착을 피한다.
  perform o.id from orders o join order_delivery_group_members m on m.order_id=o.id
    where m.group_id=p_group_id order by o.id for update of o;
  select * into v_group from order_delivery_groups where id=p_group_id and claim_token=p_claim_token for update;
  if not found then raise exception '송장 작업을 찾을 수 없습니다.'; end if;
  if p_action='booking' and v_group.state in ('claimed','booking') and nullif(p_tracking_number,'') is not null then
    if not exists(select 1 from order_delivery_group_members where group_id=p_group_id)
      or exists(select 1 from orders o join order_delivery_group_members m on m.order_id=o.id
        where m.group_id=p_group_id and not delivery_order_ready(o)) then
      raise exception '주문 상태가 변경되어 CJ 접수를 중단했습니다.';
    end if;
    update order_delivery_groups set state='booking',tracking_number=p_tracking_number,
      routing_data=p_routing_data,updated_at=now() where id=p_group_id;
  elsif p_action='registered' and v_group.state='booking' then
    update order_delivery_groups set state='registered',updated_at=now() where id=p_group_id;
    update orders set status='shipping',tracking_number=v_group.tracking_number,
      tracking_carrier='CJ대한통운',updated_at=now()
    where id in (select order_id from order_delivery_group_members where group_id=p_group_id);
  elsif p_action='registered' and v_group.state='registered' then
    null; -- 응답 유실 후 DB 완료 재시도는 멱등
  elsif (p_action='failed' and v_group.state='claimed') or (p_action='rejected' and v_group.state='booking') then
    update order_delivery_groups set state='failed',updated_at=now() where id=p_group_id;
    delete from order_delivery_group_members where group_id=p_group_id;
  else
    raise exception 'CJ 접수 결과 확인이 필요합니다. 자동 재발급을 중단했습니다. 운송장: %',coalesce(v_group.tracking_number,'미채번');
  end if;
  select * into v_group from order_delivery_groups where id=p_group_id;
  return to_jsonb(v_group);
end;
$$;

-- CJ 응답을 기다리는 짧은 구간에 주소/상태/환불 품목이 바뀌지 않도록 보호.
create function public.guard_active_order_delivery() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_order_id bigint;
begin
  if tg_table_name='orders' then v_order_id:=old.id; else v_order_id:=old.order_id; end if;
  if exists(select 1 from order_delivery_group_members m join order_delivery_groups g on g.id=m.group_id
      where m.order_id=v_order_id and (g.state='booking' or (g.state='claimed' and g.updated_at>now()-interval '10 minutes'))) then
    raise exception 'CJ 송장 처리 중입니다. 접수 결과를 확인한 뒤 주문을 변경해 주세요.';
  end if;
  return new;
end;
$$;
create trigger guard_order_delivery_update before update of status,shipping_recipient_name,shipping_recipient_phone,
  shipping_postal_code,shipping_address_line1,shipping_address_line2,shipping_memo,refund_requested_at on public.orders
  for each row when (old.* is distinct from new.*) execute function public.guard_active_order_delivery();
create trigger guard_order_delivery_item_update before update of refunded_at,quantity,order_id on public.order_items
  for each row when (old.* is distinct from new.*) execute function public.guard_active_order_delivery();

revoke all on function public.delivery_match_key(public.orders),public.delivery_order_ready(public.orders),
  public.admin_plan_order_deliveries(bigint[]),public.admin_claim_order_delivery(bigint[]),
  public.admin_transition_order_delivery(uuid,uuid,text,text,jsonb),public.guard_active_order_delivery()
  from public,anon,authenticated;
grant execute on function public.delivery_match_key(public.orders),public.delivery_order_ready(public.orders),
  public.admin_plan_order_deliveries(bigint[]),public.admin_claim_order_delivery(bigint[]),
  public.admin_transition_order_delivery(uuid,uuid,text,text,jsonb) to service_role;
commit;
