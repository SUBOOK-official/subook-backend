-- 관리자 전용 계측 상태와 CRM 대조군 도구. 고객 메시지는 발송하지 않는다.
-- 원본 주문/회원/수거 데이터는 변경하지 않으며, 대상은 실험 생성 시 고정한다.
-- 롤백: 관리자 실험 UI 제거. 실험 기록은 보존한다.
begin;
create table public.retention_experiments (
  id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 2 and 80),
  created_at timestamptz not null default clock_timestamp(), created_by uuid not null default auth.uid(),
  started_at timestamptz, window_days integer not null default 14 check(window_days between 7 and 28),
  cost integer not null default 0 check(cost>=0)
);
create table public.retention_experiment_members (
  experiment_id uuid references public.retention_experiments(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  arm text not null check(arm in ('treatment','holdout')),
  primary key(experiment_id,user_id)
);
alter table public.retention_experiments enable row level security;
alter table public.retention_experiment_members enable row level security;
revoke all on public.retention_experiments,public.retention_experiment_members from public,anon,authenticated;
grant all on public.retention_experiments,public.retention_experiment_members to service_role;

create function public.admin_create_retention_experiment(p_name text,p_window_days integer default 14)
returns uuid language plpgsql security definer set search_path='' as $function$
declare experiment_id uuid;
begin
  if not public.is_admin_user() then raise exception '관리자 권한이 필요합니다.' using errcode='42501'; end if;
  if length(btrim(coalesce(p_name,''))) not between 2 and 80 or p_window_days is null or p_window_days not between 7 and 28 then raise exception '실험 이름과 관측 기간을 확인하세요.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('subook-retention-assignment',0));
  insert into public.retention_experiments(name,window_days) values(btrim(p_name),p_window_days) returning id into experiment_id;
  insert into public.retention_experiment_members(experiment_id,user_id,arm)
    select experiment_id,m.user_id,
      case when get_byte(decode(md5(experiment_id::text||':'||m.user_id::text),'hex'),0)<128 then 'holdout' else 'treatment' end
    from public.member_profiles m
    where m.marketing_opt_in=true and not coalesce(m.is_blocked,false)
      and m.personal_data_erased_at is null and m.withdrawal_requested_at is null
      and exists(select 1 from public.orders o where o.user_id=m.user_id and o.payment_status in ('paid','refunded')
        and coalesce(o.paid_at,o.pg_approved_at)>=clock_timestamp()-interval '90 days')
      and not exists(select 1 from public.orders o where o.user_id=m.user_id and o.payment_status in ('paid','refunded')
        and coalesce(o.paid_at,o.pg_approved_at)>=clock_timestamp()-interval '14 days')
      and not exists(select 1 from public.retention_experiment_members a join public.retention_experiments e on e.id=a.experiment_id
        where a.user_id=m.user_id and e.created_at>=clock_timestamp()-interval '30 days');
  if not found then raise exception '조건에 맞는 대상이 없습니다. 최근 14~90일 구매·마케팅 동의·30일 중복 제외 기준입니다.'; end if;
  return experiment_id;
end;
$function$;

create function public.admin_start_retention_experiment(p_id uuid,p_cost integer default 0)
returns void language plpgsql security definer set search_path='' as $function$
begin
  if not public.is_admin_user() then raise exception '관리자 권한이 필요합니다.' using errcode='42501'; end if;
  if p_cost is null or p_cost<0 then raise exception '비용은 0원 이상이어야 합니다.'; end if;
  if (select count(distinct arm) from public.retention_experiment_members where experiment_id=p_id)<>2 then
    raise exception '발송군과 대조군이 모두 있어야 시작할 수 있습니다.';
  end if;
  -- 생성 후 오래된 대상은 현재의 자격과 다를 수 있어 시작하지 않는다. 시작 시간 덮어쓰기 금지.
  update public.retention_experiments set started_at=clock_timestamp(),cost=p_cost
    where id=p_id and started_at is null and created_at>=clock_timestamp()-interval '24 hours';
  if not found then raise exception '이미 시작했거나 준비 후 24시간이 지났습니다.'; end if;
end;
$function$;

create function public.admin_retention_experiments()
returns jsonb language plpgsql security definer set search_path='' as $function$
declare result jsonb;
begin
  if not public.is_admin_user() then raise exception '관리자 권한이 필요합니다.' using errcode='42501'; end if;
  with experiments as (select * from public.retention_experiments order by created_at desc limit 20),
  member_results as (
    select e.id,a.user_id,a.arm,
      coalesce(m.marketing_opt_in,false) and not coalesce(m.is_blocked,false) and m.personal_data_erased_at is null and m.withdrawal_requested_at is null as contactable,
      count(o.id)::integer orders,
      coalesce(sum(greatest(0,o.total_amount-case when o.payment_status='refunded' then o.total_amount else coalesce(o.refunded_amount,0) end)),0) net_revenue
    from experiments e join public.retention_experiment_members a on a.experiment_id=e.id
    left join public.member_profiles m on m.user_id=a.user_id
    left join public.orders o on o.user_id=a.user_id and o.payment_status in ('paid','refunded')
      and coalesce(o.paid_at,o.pg_approved_at)>=e.started_at
      and coalesce(o.paid_at,o.pg_approved_at)<e.started_at+make_interval(days=>e.window_days)
    group by e.id,a.user_id,a.arm,m.marketing_opt_in,m.is_blocked,m.personal_data_erased_at,m.withdrawal_requested_at
  ), arms as (
    select id,arm,count(*)::integer members,count(*) filter(where orders>0)::integer buyers,sum(orders) orders,sum(net_revenue) net_revenue,
      count(*) filter(where contactable)::integer contactable
    from member_results group by id,arm
  ) select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.name,'createdAt',e.created_at,
    'startedAt',e.started_at,'windowDays',e.window_days,'cost',e.cost,
    'mature',e.started_at+make_interval(days=>e.window_days)<=clock_timestamp(),
    'arms',coalesce((select jsonb_agg(to_jsonb(s)-'id') from arms s where s.id=e.id),'[]'::jsonb),
    'contactIds',coalesce((select jsonb_agg(user_id) from member_results s where s.id=e.id and s.arm='treatment' and s.contactable),'[]'::jsonb)
  ) order by e.created_at desc),'[]'::jsonb) into result from experiments e;
  return result;
end;
$function$;

create function public.admin_growth_tracking_health(p_from date,p_to date,p_ga_transaction_ids text[] default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare result jsonb;
begin
  if not public.is_admin_user() then raise exception '관리자 권한이 필요합니다.' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 or coalesce(cardinality(p_ga_transaction_ids),0)>10000 then raise exception '조회 범위를 확인하세요.'; end if;
  with paid as materialized (
    select o.* from public.orders o where o.payment_status in ('paid','refunded')
      and coalesce(o.paid_at,o.pg_approved_at)>=(p_from::timestamp at time zone 'Asia/Seoul')
      and coalesce(o.paid_at,o.pg_approved_at)<((p_to+1)::timestamp at time zone 'Asia/Seoul')
  ), campaigns as (
    select attribution#>>'{last_touch,campaign_id}' campaign_id,attribution#>>'{last_touch,campaign}' campaign,
      attribution#>>'{last_touch,source}' source,attribution#>>'{last_touch,medium}' medium,count(*) orders,
      sum(greatest(0,total_amount-case when payment_status='refunded' then total_amount else coalesce(refunded_amount,0) end)) net_revenue
    from paid group by 1,2,3,4
  ) select jsonb_build_object(
    'from',p_from,'to',p_to,'serverEnabled',(select enabled from public.ga_tracking_config where singleton),
    'paidOrders',count(*),'matchedOrders',case when p_ga_transaction_ids is not null then count(*) filter(where order_number=any(p_ga_transaction_ids)) end,
    'gaTransactionCount',case when p_ga_transaction_ids is not null then (select count(distinct id) from unnest(p_ga_transaction_ids) id) end,
    'serverAccepted',count(*) filter(where q.status='accepted'),'serverPending',count(*) filter(where q.status='pending'),'serverFailed',count(*) filter(where q.status='failed'),
    'pickupRequests',(select count(*) from public.pickup_requests where created_at>=(p_from::timestamp at time zone 'Asia/Seoul') and created_at<((p_to+1)::timestamp at time zone 'Asia/Seoul')),
    'campaigns',coalesce((select jsonb_agg(to_jsonb(c) order by c.orders desc) from campaigns c),'[]'::jsonb)
  ) into result from paid o left join public.ga_purchase_outbox q on q.order_id=o.id;
  return result;
end;
$function$;
revoke all on function public.admin_create_retention_experiment(text,integer),public.admin_start_retention_experiment(uuid,integer),public.admin_retention_experiments(),public.admin_growth_tracking_health(date,date,text[]) from public,anon;
grant execute on function public.admin_create_retention_experiment(text,integer),public.admin_start_retention_experiment(uuid,integer),public.admin_retention_experiments(),public.admin_growth_tracking_health(date,date,text[]) to authenticated,service_role;
commit;
