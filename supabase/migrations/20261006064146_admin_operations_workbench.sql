-- 운영 화면 개편: 신규 읽기 RPC와 관리자 전용 작업 기록. 결제/환불/정산 처리 함수는 변경하지 않는다.
CREATE OR REPLACE FUNCTION public.list_admin_work_orders(p_search text DEFAULT NULL::text, p_statuses text[] DEFAULT NULL::text[], p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_view text DEFAULT 'all', p_user_id uuid DEFAULT NULL, p_order_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_items jsonb;
  v_total integer;
begin
  if not coalesce(public.is_admin_user(), false) then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
  from public.orders o
  left join public.member_profiles p on p.user_id = o.user_id
  where
    (p_search is null or p_search = '' or
      o.order_number ilike '%' || p_search || '%' or
      p.name ilike '%' || p_search || '%' or
      p.email ilike '%' || p_search || '%' or
      p.phone ilike '%' || p_search || '%' or
      o.shipping_recipient_name ilike '%' || p_search || '%' or
      o.shipping_recipient_phone ilike '%' || p_search || '%')
    and (p_user_id is null or o.user_id = p_user_id)
    and (p_order_id is null or o.id = p_order_id)
    and (
      p_view = 'all'
      or (p_view = 'fulfillment' and o.status in ('paid','preparing') and (o.refund_requested_at is null or o.refund_request_resolved_at is not null))
      or (p_view = 'refunds' and o.refund_requested_at is not null and o.refund_request_resolved_at is null and o.status <> 'refunded')
      or (p_view = 'returns' and o.return_registered_at is not null and o.return_recovered_at is null)
      or (p_view = 'restock' and exists(select 1 from public.order_items held where held.order_id = o.id and held.restock_held_at is not null))
    )
    and (p_statuses is null or o.status = any(p_statuses))
    and (p_from_date is null or o.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul'))
    and (p_to_date is null or o.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul'));

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      -- 결제 확인 시각 2종 (2026-07-13: 무통장=paid_at, 레거시 PG=pg_approved_at 폴백)
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      -- 할인 필드 3종 (2026-07-06 피드백: 주문 상세에 쿠폰 사용액 표시)
      'discount_amount', o.discount_amount,
      'coupon_discount_amount', o.coupon_discount_amount,
      -- 포인트 사용액 (2026-09-02 포인트 제도 — total_amount에 이미 차감 반영)
      'points_used', coalesce(o.points_used, 0),
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'shipping_recipient_name', o.shipping_recipient_name,
      'shipping_recipient_phone', o.shipping_recipient_phone,
      'shipping_postal_code', o.shipping_postal_code,
      'shipping_address_line1', o.shipping_address_line1,
      'shipping_address_line2', o.shipping_address_line2,
      'shipping_memo', o.shipping_memo,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      -- 환불 메타 4종
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      -- 환불 신청 해소 시각 (2026-08-24 자동확정 보류 — null이면 확정·송금 보류 중)
      'refund_request_resolved_at', o.refund_request_resolved_at,
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- 반품 수거 3종 (2026-08-24 반품 수거 자동화 — cust_use_no는 서버 전용이라 미노출)
      'return_tracking_number', o.return_tracking_number,
      'return_registered_at', o.return_registered_at,
      'return_recovered_at', o.return_recovered_at,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      -- 비회원 주문 여부 (2026-08-03 게스트 주문 도입)
      'is_guest', (o.user_id is null),
      'buyer_email', p.email,
      'buyer_name', p.name,
      'buyer_phone', p.phone,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          -- 품목별 환불 상태 (2026-08-01 부분환불)
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount,
          'refund_reason', oi.refund_reason,
          -- 재입고 보류 (2026-08-24 반품 수거 — 실물 회수 전 재노출 방지)
          'restock_held_at', oi.restock_held_at,
          -- 피킹 동선용 재고 메타 (2026-07-18: 위치로 가서 일련번호로 실물 확인)
          'book_serial_number', b.serial_number,
          'book_location', b.location,
          'book_status', b.status,
          -- 수북 자체 판매 교재 품목은 위치·일련번호가 없는 게 정상 (2026-09-15)
          'product_id', oi.product_id,
          'is_direct_sale', exists (select 1 from public.direct_sale_products ds where ds.product_id = oi.product_id)
        ) order by oi.id)
        from public.order_items oi
        left join public.books b on b.id = oi.book_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    left join public.member_profiles p on p.user_id = o.user_id
    where
      (p_search is null or p_search = '' or
        o.order_number ilike '%' || p_search || '%' or
        p.name ilike '%' || p_search || '%' or
        p.email ilike '%' || p_search || '%' or
        p.phone ilike '%' || p_search || '%' or
        o.shipping_recipient_name ilike '%' || p_search || '%' or
        o.shipping_recipient_phone ilike '%' || p_search || '%')
      and (p_user_id is null or o.user_id = p_user_id)
    and (p_order_id is null or o.id = p_order_id)
    and (
      p_view = 'all'
      or (p_view = 'fulfillment' and o.status in ('paid','preparing') and (o.refund_requested_at is null or o.refund_request_resolved_at is not null))
      or (p_view = 'refunds' and o.refund_requested_at is not null and o.refund_request_resolved_at is null and o.status <> 'refunded')
      or (p_view = 'returns' and o.return_registered_at is not null and o.return_recovered_at is null)
      or (p_view = 'restock' and exists(select 1 from public.order_items held where held.order_id = o.id and held.restock_held_at is not null))
    )
    and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul'))
      and (p_to_date is null or o.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul'))
    order by
      -- 미해소 환불 신청 최우선 (해소된 신청은 일반 정렬)
      (case
        when o.refund_requested_at is not null
         and o.refund_request_resolved_at is null
         and o.status <> 'refunded' then 0
        else 1
      end),
      o.created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(coalesce(p_offset, 0), 0)
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$$;
REVOKE ALL ON FUNCTION public.list_admin_work_orders(text,text[],date,date,integer,integer,text,uuid,bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.list_admin_work_orders(text,text[],date,date,integer,integer,text,uuid,bigint) TO authenticated;

-- 신규 테이블만 추가한다. 롤백은 이전 앱으로 복귀하고 기록 테이블은 보존한다.
create table public.admin_cs_cases (
  id bigint generated always as identity primary key,
  title text not null check (length(btrim(title)) between 1 and 160),
  customer_name text not null default '',
  contact text not null default '',
  member_user_id uuid references auth.users(id) on delete set null,
  order_id bigint references public.orders(id),
  pickup_request_id bigint references public.pickup_requests(id),
  assignee text not null default '',
  status text not null default 'open' check (status in ('open','waiting','done')),
  priority text not null default 'normal' check (priority in ('normal','urgent')),
  due_date date,
  note text not null default '' check (length(note) <= 10000),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index admin_cs_cases_queue on public.admin_cs_cases(status, due_date, updated_at desc);
alter table public.admin_cs_cases enable row level security;
revoke all on public.admin_cs_cases from anon, authenticated;
grant select, insert, update on public.admin_cs_cases to authenticated;
grant usage, select on sequence public.admin_cs_cases_id_seq to authenticated;
create policy admin_cs_cases_read on public.admin_cs_cases for select to authenticated using (public.is_admin_user());
create policy admin_cs_cases_insert on public.admin_cs_cases for insert to authenticated with check (public.is_admin_user() and created_by = auth.uid());
create policy admin_cs_cases_update on public.admin_cs_cases for update to authenticated using (public.is_admin_user()) with check (public.is_admin_user());

create table public.admin_work_jobs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (length(kind) between 1 and 80),
  label text not null check (length(label) between 1 and 200),
  status text not null default 'running' check (status in ('running','completed','partial','failed','interrupted')),
  total integer not null default 0 check (total >= 0),
  done integer not null default 0 check (done >= 0 and done <= total),
  target_ids jsonb not null default '[]'::jsonb check (jsonb_typeof(target_ids)='array'),
  failures jsonb not null default '[]'::jsonb check (jsonb_typeof(failures) = 'array'),
  result_href text check (result_href is null or result_href like '/admin/%'),
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index admin_work_jobs_recent on public.admin_work_jobs(created_at desc);
alter table public.admin_work_jobs enable row level security;
revoke all on public.admin_work_jobs from anon, authenticated;
grant select, insert, update on public.admin_work_jobs to authenticated;
create policy admin_work_jobs_read on public.admin_work_jobs for select to authenticated using (public.is_admin_user());
create policy admin_work_jobs_insert on public.admin_work_jobs for insert to authenticated with check (public.is_admin_user() and created_by = auth.uid());
create policy admin_work_jobs_update on public.admin_work_jobs for update to authenticated using (public.is_admin_user() and created_by = auth.uid()) with check (public.is_admin_user() and created_by = auth.uid());

create table public.admin_operation_events (
  id bigint generated always as identity primary key,
  entity_type text not null,
  entity_id text not null,
  action text not null,
  actor_id uuid default auth.uid(),
  changed_fields jsonb not null default '[]',
  created_at timestamptz not null default now()
);
create index admin_operation_events_entity on public.admin_operation_events(entity_type, entity_id, created_at desc);
create index admin_operation_events_recent on public.admin_operation_events(created_at desc);
alter table public.admin_operation_events enable row level security;
revoke all on public.admin_operation_events from anon, authenticated;
grant select on public.admin_operation_events to authenticated;
create policy admin_operation_events_read on public.admin_operation_events for select to authenticated using (public.is_admin_user());

create function public.record_admin_operation() returns trigger language plpgsql security definer set search_path = public as $$
declare v_old jsonb := '{}'::jsonb; v_new jsonb := '{}'::jsonb; v_fields jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and tg_table_name in ('admin_cs_cases','admin_work_jobs') then
    new.updated_at := clock_timestamp(); v_new := to_jsonb(new);
  end if;
  -- 값 자체(연락처/계좌/본문)는 복제하지 않고 변경 필드만 기록한다.
  select coalesce(jsonb_agg(k order by k), '[]') into v_fields
  from (select jsonb_object_keys(v_old || v_new) k) keys
  where k <> 'updated_at' and v_old->k is distinct from v_new->k;
  if jsonb_array_length(v_fields) > 0 then
    insert into public.admin_operation_events(entity_type,entity_id,action,changed_fields)
      values(tg_table_name,coalesce(v_new->>'id',v_old->>'id',v_new->>'product_id',v_old->>'product_id'),lower(tg_op),v_fields);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.record_admin_operation() from public, anon, authenticated;
create trigger admin_cs_cases_record before insert or update on public.admin_cs_cases for each row execute function public.record_admin_operation();
create trigger admin_work_jobs_record before insert or update on public.admin_work_jobs for each row execute function public.record_admin_operation();
create trigger admin_coupons_record after insert or update or delete on public.coupons for each row execute function public.record_admin_operation();
create trigger admin_notices_record after insert or update or delete on public.notices for each row execute function public.record_admin_operation();
create trigger admin_faqs_record after insert or update or delete on public.faqs for each row execute function public.record_admin_operation();

create function public.admin_operation_queue(p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not coalesce(public.is_admin_user(), false) then raise exception 'Admin access required'; end if;
  with tasks as (
    select 'refund:'||o.id as id, '환불 신청' as category, o.order_number as title,
      o.refund_requested_at as since, '/admin/orders?order='||o.id||'&detail='||o.id as href, 1 as priority
    from public.orders o where o.refund_requested_at is not null and o.refund_request_resolved_at is null and o.status <> 'refunded'
    union all
    select 'shipping:'||o.id,'출고 대기',o.order_number,coalesce(o.paid_at,o.created_at),'/admin/orders?order='||o.id||'&detail='||o.id,2
    from public.orders o where o.status in ('paid','preparing') and coalesce(o.paid_at,o.created_at) < now()-interval '2 days'
    union all
    select 'pickup:'||p.id,'수거 접수 대기',coalesce(p.pickup_recipient_name,'수거 신청')||' #'||p.id,p.created_at,'/admin/pickups?status=pending',3
    from public.pickup_requests p where p.status='pending' and p.created_at < now()-interval '2 days'
    union all
    select 'inspection:'||s.id,'검수 대기',coalesce(s.seller_name,'검수')||' #'||s.id,s.created_at,'/admin/shipments/'||s.id,3
    from public.shipments s where s.status in ('scheduled','inspecting') and s.created_at < now()-interval '7 days'
    union all
    select 'bank:'||s.id,'정산 계좌 확인','정산 원장 #'||s.id,s.created_at,'/admin/settlements',2
    from public.settlements s where s.status in ('pending','approved') and (nullif(btrim(s.bank_name),'') is null or nullif(btrim(s.account_number),'') is null or nullif(btrim(s.account_holder),'') is null)
    union all
    select 'notice:'||n.id,'알림 발송 실패',coalesce(n.notification_type,'알림'),n.created_at,'/admin/notification-logs?status=failed',4
    from public.notification_logs n where n.status='failed' and n.created_at > now()-interval '1 day'
    union all
    select 'cs:'||c.id,'문의 처리 기한',c.title,c.created_at,'/admin/cs?case='||c.id,2
    from public.admin_cs_cases c where c.status <> 'done' and c.due_date <= (now() at time zone 'Asia/Seoul')::date
  ) select jsonb_build_object('total_count',(select count(*) from tasks),'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select * from tasks order by priority,since,id limit greatest(1,least(p_limit,100))) t),'[]')) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_operation_queue(integer) from public, anon;
grant execute on function public.admin_operation_queue(integer) to authenticated;

create function public.admin_inventory_ageing(p_days integer default 90,p_search text default '',p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  with inventory as (
    select p.id,p.title,p.cover_image_url,count(*) as quantity,sum(coalesce(b.price,0)) as inventory_value,
      min(b.created_at) as oldest_at,extract(day from now()-min(b.created_at))::integer as age_days
    from public.books b join public.products p on p.id=b.product_id
    where b.status='on_sale' and b.created_at <= now()-make_interval(days=>greatest(p_days,0))
      and (p_search='' or p.title ilike '%'||p_search||'%')
      and not exists(select 1 from public.order_items oi join public.orders o on o.id=oi.order_id where oi.book_id=b.id and (oi.restock_held_at is not null or (oi.refunded_at is null and o.status not in ('cancelled','refunded'))))
    group by p.id,p.title,p.cover_image_url
  ), recent_sales as (
    select oi.product_id,sum(oi.quantity) as sold_30d from public.order_items oi join public.orders o on o.id=oi.order_id
    where oi.refunded_at is null and o.status in ('paid','preparing','shipping','delivered','confirmed') and coalesce(o.paid_at,o.pg_approved_at,o.created_at)>=now()-interval '30 days'
    group by oi.product_id
  ), analysed as (
    select inventory.*,coalesce(s.sold_30d,0) as sold_30d,case when s.sold_30d>0 then ceil(inventory.quantity*30.0/s.sold_30d)::integer end as stock_days from inventory left join recent_sales s on s.product_id=inventory.id
  ) select jsonb_build_object('total_count',(select count(*) from inventory),'quantity',(select coalesce(sum(quantity),0) from inventory),'inventory_value',(select coalesce(sum(inventory_value),0) from inventory),'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select * from analysed order by oldest_at,id limit greatest(1,least(p_limit,100)) offset greatest(p_offset,0)) t),'[]')) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_inventory_ageing(integer,text,integer,integer) from public, anon;
grant execute on function public.admin_inventory_ageing(integer,text,integer,integer) to authenticated;

create function public.admin_settlement_exceptions(p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  with exceptions as (
    select s.id,s.order_id,o.order_number,s.book_id,b.title,s.net_amount,s.completed_at,oi.refunded_at,o.refund_requested_at,
      case when oi.refunded_at is not null then '기지급 교재 환불' else '기지급 주문 환불 신청' end as reason
    from public.settlements s join public.orders o on o.id=s.order_id join public.books b on b.id=s.book_id
    left join public.order_items oi on oi.order_id=s.order_id and oi.book_id=s.book_id
    where s.status='completed' and (oi.refunded_at is not null or (o.refund_requested_at is not null and o.refund_request_resolved_at is null and o.status <> 'refunded'))
  ) select jsonb_build_object('total_count',(select count(*) from exceptions),'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select * from exceptions order by completed_at desc,id desc limit greatest(1,least(p_limit,100)) offset greatest(p_offset,0)) t),'[]')) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_settlement_exceptions(integer,integer) from public, anon;
grant execute on function public.admin_settlement_exceptions(integer,integer) to authenticated;

create function public.admin_subscription_events()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  return coalesce((select jsonb_agg(to_jsonb(t)) from (select event_key,count(*) as total_count,max(created_at) as latest_at from public.event_subscriptions group by event_key order by max(created_at) desc) t),'[]');
end;
$$;
revoke all on function public.admin_subscription_events() from public, anon;
grant execute on function public.admin_subscription_events() to authenticated;
create or replace function public.list_admin_work_pickups(
  p_search text default null,
  p_statuses text[] default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 30,
  p_offset integer default 0,
  p_user_id uuid default null,
  p_request_id bigint default null
)
returns table (
  id bigint,
  user_id uuid,
  request_number text,
  status text,
  pickup_recipient_name text,
  pickup_recipient_phone text,
  pickup_postal_code text,
  pickup_address_line1 text,
  pickup_address_line2 text,
  pickup_memo text,
  pickup_email text,
  pickup_entrance_password text,
  desired_pickup_date date,
  expected_book_count integer,
  box_count integer,
  item_count integer,
  tracking_number text,
  tracking_carrier text,
  cj_request_id text,
  cj_pickup_registered_at timestamptz,
  cj_tracking_status text,
  cj_tracking_status_code text,
  cj_tracking_last_checked_at timestamptz,
  box_waybills jsonb,
  box_type_codes text[],
  created_at timestamptz,
  updated_at timestamptz,
  member_since timestamptz,
  phone_verified boolean,
  prior_pickup_count integer,
  duplicate_pending_count integer,
  merged_into_id bigint,
  merged_into_request_number text,
  merged_child_count integer,
  merged_child_numbers jsonb,
  bridged_shipment_id bigint,
  bridged_book_count integer,
  items jsonb,
  latest_logistics_event jsonb,
  total_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits,
      coalesce(cardinality(p_statuses), 0) as status_count
  ),
  filtered_pickups as (
    select pr.*
    from public.pickup_requests pr
    cross join params
    where public.is_admin_user()
      and (p_user_id is null or pr.user_id = p_user_id)
      and (p_request_id is null or pr.id = p_request_id)
      and (
        params.search_term = ''
        or pr.request_number ilike '%' || params.search_term || '%'
        or pr.pickup_recipient_name ilike '%' || params.search_term || '%'
        or pr.pickup_recipient_phone ilike '%' || params.search_term || '%'
        or coalesce(pr.tracking_number, '') ilike '%' || params.search_term || '%'
        or (
          params.search_digits <> ''
          and regexp_replace(pr.pickup_recipient_phone, '[^0-9]', '', 'g') like '%' || params.search_digits || '%'
        )
      )
      and (
        params.status_count = 0
        or pr.status = any(p_statuses)
      )
      and (
        p_from_date is null
        or pr.created_at >= (p_from_date::timestamp at time zone 'Asia/Seoul')
      )
      and (
        p_to_date is null
        or pr.created_at < ((p_to_date + 1)::timestamp at time zone 'Asia/Seoul')
      )
  )
  select
    fp.id,
    fp.user_id,
    fp.request_number,
    fp.status,
    fp.pickup_recipient_name,
    fp.pickup_recipient_phone,
    fp.pickup_postal_code,
    fp.pickup_address_line1,
    fp.pickup_address_line2,
    fp.pickup_memo,
    fp.pickup_email,
    fp.pickup_entrance_password,
    fp.desired_pickup_date,
    fp.expected_book_count,
    fp.box_count,
    fp.item_count,
    fp.tracking_number,
    fp.tracking_carrier,
    fp.cj_request_id,
    fp.cj_pickup_registered_at,
    fp.cj_tracking_status,
    fp.cj_tracking_status_code,
    fp.cj_tracking_last_checked_at,
    fp.box_waybills,
    fp.box_type_codes,
    fp.created_at,
    fp.updated_at,
    -- 접수 전 신뢰 신호 (장난/시험 신청 선별용, 2026-08-10)
    mp.created_at as member_since,
    coalesce(
      mp.phone_verified_at is not null
        and mp.verified_phone = regexp_replace(coalesce(fp.pickup_recipient_phone, ''), '[^0-9]', '', 'g'),
      false
    ) as phone_verified,
    coalesce((
      select count(*)::integer
      from public.pickup_requests prior
      where prior.user_id = fp.user_id
        and prior.id <> fp.id
        and prior.status in ('pickup_scheduled', 'picking_up', 'arrived', 'inspecting', 'inspected', 'completed')
    ), 0) as prior_pickup_count,
    coalesce((
      select count(*)::integer
      from public.pickup_requests dup
      where dup.id <> fp.id
        and dup.status = 'pending'
        and (
          dup.user_id = fp.user_id
          or regexp_replace(coalesce(dup.pickup_recipient_phone, ''), '[^0-9]', '', 'g')
             = regexp_replace(coalesce(fp.pickup_recipient_phone, ''), '[^0-9]', '', 'g')
        )
    ), 0) as duplicate_pending_count,
    -- 병합 상태 (2026-08-10)
    fp.merged_into_id,
    (select parent.request_number from public.pickup_requests parent where parent.id = fp.merged_into_id)
      as merged_into_request_number,
    coalesce((
      select count(*)::integer
      from public.pickup_requests child
      where child.merged_into_id = fp.id
    ), 0) as merged_child_count,
    coalesce((
      select jsonb_agg(child.request_number order by child.created_at)
      from public.pickup_requests child
      where child.merged_into_id = fp.id
    ), '[]'::jsonb) as merged_child_numbers,
    (
      select s.id from public.shipments s
      where s.pickup_request_id = fp.id
      order by s.id limit 1
    ) as bridged_shipment_id,
    coalesce((
      select count(*)::integer
      from public.books b
      join public.shipments s on s.id = b.shipment_id
      where s.pickup_request_id = fp.id
    ), 0) as bridged_book_count,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pi.id,
        'title', pi.title,
        'subject', pi.subject,
        'brand', pi.brand,
        'book_type', pi.book_type,
        'published_year', pi.published_year,
        'instructor_name', pi.instructor_name,
        'original_price', pi.original_price,
        'condition_memo', pi.condition_memo,
        'is_manual_entry', pi.is_manual_entry
      ) order by pi.id)
      from public.pickup_items pi
      where pi.pickup_request_id = fp.id
    ), '[]'::jsonb) as items,
    (
      select jsonb_build_object(
        'event_type', ple.event_type,
        'status', ple.status,
        'tracking_number', ple.tracking_number,
        'status_code', ple.status_code,
        'status_text', ple.status_text,
        'error_message', ple.error_message,
        'created_at', ple.created_at
      )
      from public.pickup_logistics_events ple
      where ple.pickup_request_id = fp.id
      order by ple.created_at desc, ple.id desc
      limit 1
    ) as latest_logistics_event,
    count(*) over()::integer as total_count
  from filtered_pickups fp
  left join public.member_profiles mp
    on mp.user_id = fp.user_id
  order by fp.created_at desc, fp.id desc
  offset greatest(0, coalesce(p_offset, 0))
  limit greatest(1, least(coalesce(p_limit, 30), 200));
$$;
revoke all on function public.list_admin_work_pickups(text,text[],date,date,integer,integer,uuid,bigint) from public, anon;
grant execute on function public.list_admin_work_pickups(text,text[],date,date,integer,integer,uuid,bigint) to authenticated;

notify pgrst, 'reload schema';

create function public.admin_operation_history(p_search text default '',p_entity text default '',p_id text default '',p_limit integer default 50,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  with history as (
    select 'event:'||e.id as id,e.entity_type,e.entity_id,e.action,e.actor_id,e.created_at,e.changed_fields::text as detail
    from public.admin_operation_events e
    union all
    select 'book:'||b.id,'books',b.book_id::text,b.field,b.changed_by,b.changed_at,coalesce(b.old_value,'—')||' → '||coalesce(b.new_value,'—') from public.book_change_logs b
    union all
    select 'product:'||p.id,'products',p.product_id::text,'status',p.changed_by,p.changed_at,coalesce(p.old_status,'—')||' → '||p.new_status from public.product_status_logs p
  ), filtered as (select * from history where (p_entity='' or entity_type=p_entity) and (p_id='' or entity_id=p_id) and (p_search='' or entity_id ilike '%'||p_search||'%' or action ilike '%'||p_search||'%' or detail ilike '%'||p_search||'%'))
  select jsonb_build_object('total_count',(select count(*) from filtered),'items',coalesce((select jsonb_agg(to_jsonb(t)) from (select * from filtered order by created_at desc,id desc limit greatest(1,least(p_limit,100)) offset greatest(p_offset,0)) t),'[]')) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_operation_history(text,text,text,integer,integer) from public, anon;
grant execute on function public.admin_operation_history(text,text,text,integer,integer) to authenticated;

-- 상태값 변경만 기록한다. 결제·환불·정산 실행과 알림 발송은 기존 함수가 담당한다.
create trigger admin_orders_record after insert or update on public.orders for each row execute function public.record_admin_operation();
create trigger admin_pickups_record after insert or update on public.pickup_requests for each row execute function public.record_admin_operation();
create trigger admin_shipments_record after insert or update on public.shipments for each row execute function public.record_admin_operation();

-- 작업 체크만 저장하며 주문/결제/물류 상태는 변경하지 않는다.
create table public.admin_fulfillment_checks (
  order_id bigint primary key references public.orders(id),
  picked_item_ids bigint[] not null default '{}',
  packed_at timestamptz,
  updated_by uuid references auth.users(id) default auth.uid(),
  updated_at timestamptz not null default now()
);
alter table public.admin_fulfillment_checks enable row level security;
create policy fulfillment_admin_read on public.admin_fulfillment_checks for select to authenticated using(public.is_admin_user());
revoke all on public.admin_fulfillment_checks from public,anon,authenticated;
grant select on public.admin_fulfillment_checks to authenticated;

create function public.admin_set_fulfillment_check(p_order_id bigint,p_item_id bigint default null,p_picked boolean default null,p_packed boolean default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.admin_fulfillment_checks; v_order public.orders; v_items bigint[];
begin
  if not coalesce(public.is_admin_user(),false) then raise exception 'Admin access required'; end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found or v_order.status not in ('paid','preparing') or (v_order.refund_requested_at is not null and v_order.refund_request_resolved_at is null) then
    raise exception '출고 대기 상태가 변경되었습니다. 목록을 새로 조회해 주세요.';
  end if;
  select coalesce(array_agg(id),'{}') into v_items from public.order_items where order_id=p_order_id and refunded_at is null;
  insert into public.admin_fulfillment_checks(order_id) values(p_order_id) on conflict do nothing;
  select * into v_row from public.admin_fulfillment_checks where order_id=p_order_id for update;
  if p_picked is not null then
    if p_item_id is null or not (p_item_id=any(v_items)) then raise exception '유효한 출고 품목이 아닙니다.'; end if;
    v_row.picked_item_ids=array_remove(v_row.picked_item_ids,p_item_id);
    if p_picked then v_row.picked_item_ids=array_append(v_row.picked_item_ids,p_item_id);
    else v_row.packed_at=null; end if;
  end if;
  if p_packed is true then
    if cardinality(v_items)=0 or not (v_row.picked_item_ids @> v_items) then raise exception '모든 품목의 피킹을 먼저 확인해 주세요.'; end if;
    v_row.packed_at=now();
  elsif p_packed is false then v_row.packed_at=null;
  end if;
  update public.admin_fulfillment_checks set picked_item_ids=v_row.picked_item_ids,packed_at=v_row.packed_at,updated_by=auth.uid(),updated_at=clock_timestamp() where order_id=p_order_id returning * into v_row;
  return to_jsonb(v_row);
end $$;
revoke all on function public.admin_set_fulfillment_check(bigint,bigint,boolean,boolean) from public,anon;
grant execute on function public.admin_set_fulfillment_check(bigint,bigint,boolean,boolean) to authenticated;
notify pgrst,'reload schema';
