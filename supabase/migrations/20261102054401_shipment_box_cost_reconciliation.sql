-- 박스 수 저장과 미지급 정산 재계산을 한 트랜잭션으로 처리한다.
-- 기지급 원장은 불변. 비용 반환은 별도 원장으로 생성해 실제 송금 후 완료한다.
-- 기존 데이터 일괄 수정 없음. 롤백 시 새 트리거/RPC 진입을 중단하되 지급 원장은 보존한다.
create table public.settlement_box_cost_adjustments (
  -- 기존 정산과 ID 공간을 공유하여 엑셀 감사·알림 멱등키도 충돌하지 않는다.
  id bigint primary key default nextval('public.settlements_id_seq'),
  shipment_id bigint not null references public.shipments(id),
  reference_settlement_id bigint not null references public.settlements(id),
  amount integer not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending','completed','cancelled')),
  scheduled_date date not null default (now() at time zone 'Asia/Seoul')::date,
  completed_at timestamptz,
  transfer_reference text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status='completed') = (completed_at is not null))
);
create unique index settlement_box_cost_one_pending on public.settlement_box_cost_adjustments(shipment_id) where status='pending';
alter table public.settlement_box_cost_adjustments enable row level security;
revoke all on public.settlement_box_cost_adjustments from public,anon,authenticated;
grant select on public.settlement_box_cost_adjustments to authenticated;
create policy settlement_box_cost_read on public.settlement_box_cost_adjustments for select to authenticated
using (public.is_admin_user() or exists(select 1 from public.shipments s where s.id=shipment_id and s.user_id=auth.uid()));
create trigger settlement_box_cost_record after insert or update on public.settlement_box_cost_adjustments
for each row execute function public.record_admin_operation();

-- 내부 조회 전용. 직접 API 접근은 금지하고 기존 관리자/본인 조회 RPC의 권한 검사를 유지한다.
create view public.settlement_payout_rows with (security_invoker=true) as
select st.* from public.settlements st
union all
select (jsonb_populate_record(null::public.settlements,to_jsonb(st)||jsonb_build_object(
  'id',a.id,'seller_user_id',sh.user_id,'order_id',null,'order_item_id',null,
  'sale_amount',0,'fee_percent',0,'fee_amount',0,'net_amount',a.amount,'box_cost_deducted',-a.amount,
  'status',a.status,'scheduled_date',a.scheduled_date,'approved_at',null,'completed_at',a.completed_at,
  'created_at',a.created_at,'updated_at',a.updated_at,'transfer_reference',a.transfer_reference,
  'cancelled_at',case when a.status='cancelled' then a.updated_at else null end,
  'recovery_required_at',null,'refund_reason',null,'sale_source','box_cost_adjustment','manual_sold_at',null
))).*
from public.settlement_box_cost_adjustments a
join public.settlements st on st.id=a.reference_settlement_id
join public.shipments sh on sh.id=a.shipment_id;
revoke all on public.settlement_payout_rows from public,anon,authenticated;

create function public.reconcile_shipment_box_cost() returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_target integer;
  v_pending_cost integer;
  v_pending_adjustment integer;
  v_fixed_cost integer;
  v_remaining integer;
  v_refund integer;
  v_deduct integer;
  v_new_pending_cost integer:=0;
  v_reference bigint;
  v_row record;
begin
  if new.box_count is null or new.box_count<0 or new.box_count>10000 then
    raise exception '박스 수는 0~10,000 사이의 정수로 입력해 주세요.';
  end if;
  -- UPDATE가 수거 행을 이미 잠근 상태. 지급 처리도 수거→정산 순서로 잠근다.
  perform st.id from public.settlements st join public.books b on b.id=st.book_id
    where b.shipment_id=new.id order by st.id for update of st;
  perform id from public.settlement_box_cost_adjustments where shipment_id=new.id order by id for update;
  if exists(select 1 from public.settlements st join public.books b on b.id=st.book_id
    left join public.orders o on o.id=st.order_id where b.shipment_id=new.id and
    (st.status='recovery_required' or (o.refund_requested_at is not null and o.refund_request_resolved_at is null)
      or exists(select 1 from public.order_return_cases rc where rc.order_id=st.order_id and rc.status not in ('refunded','cancelled')))) then
    raise exception '환불·회수 처리 중인 정산이 있습니다. 처리를 마친 뒤 박스 수를 변경해 주세요.';
  end if;
  select coalesce(sum(st.box_cost_deducted),0) into v_pending_cost
    from public.settlements st join public.books b on b.id=st.book_id
    where b.shipment_id=new.id and st.status in ('pending','approved');
  select coalesce(sum(amount),0) into v_pending_adjustment from public.settlement_box_cost_adjustments
    where shipment_id=new.id and status='pending';
  -- 누적 차감에는 반환 예정/완료분이 이미 반영되어 있다. 미지급 반환을 되돌려 고정분 산출.
  v_fixed_cost:=old.box_cost_charged-v_pending_cost+v_pending_adjustment;
  if v_fixed_cost<0 then raise exception '누적 상품화 비용 기록을 먼저 확인해 주세요.'; end if;
  v_target:=new.box_count*5000;
  v_refund:=greatest(0,v_fixed_cost-v_target);
  v_remaining:=greatest(0,v_target-v_fixed_cost);
  for v_row in select st.* from public.settlements st join public.books b on b.id=st.book_id
    where b.shipment_id=new.id and st.status in ('pending','approved') order by st.created_at,st.id
  loop
    v_deduct:=least(v_remaining,greatest(0,v_row.sale_amount-v_row.fee_amount));
    update public.settlements set box_cost_deducted=v_deduct,net_amount=v_row.sale_amount-v_row.fee_amount-v_deduct
      where id=v_row.id and (box_cost_deducted is distinct from v_deduct or net_amount is distinct from v_row.sale_amount-v_row.fee_amount-v_deduct);
    v_remaining:=v_remaining-v_deduct;
    v_new_pending_cost:=v_new_pending_cost+v_deduct;
  end loop;
  if v_refund>0 then
    select st.id into v_reference from public.settlements st join public.books b on b.id=st.book_id
      where b.shipment_id=new.id and st.status='completed' and st.box_cost_deducted>0 order by st.id limit 1;
    if v_reference is null then raise exception '지급 완료된 상품화 비용 기록을 먼저 확인해 주세요.'; end if;
    insert into public.settlement_box_cost_adjustments(shipment_id,reference_settlement_id,amount)
      values(new.id,v_reference,v_refund)
      on conflict (shipment_id) where status='pending' do update set amount=excluded.amount,updated_at=now()
      where settlement_box_cost_adjustments.amount is distinct from excluded.amount;
  else
    update public.settlement_box_cost_adjustments set status='cancelled',updated_at=now()
      where shipment_id=new.id and status='pending';
  end if;
  new.box_cost_charged:=v_fixed_cost+v_new_pending_cost-v_refund;
  return new;
end;
$$;
revoke all on function public.reconcile_shipment_box_cost() from public,anon,authenticated;
create trigger zz_reconcile_shipment_box_cost before update of box_count on public.shipments
for each row execute function public.reconcile_shipment_box_cost();

create function public.admin_update_shipment_box_count(p_shipment_id bigint,p_box_count integer,p_expected_box_count integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_shipment public.shipments;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  update public.shipments set box_count=p_box_count where id=p_shipment_id and box_count=p_expected_box_count returning * into v_shipment;
  if not found then raise exception '박스 수가 변경됐습니다. 새로고침 후 다시 확인해 주세요.'; end if;
  return jsonb_build_object('box_count',v_shipment.box_count,'box_cost_charged',v_shipment.box_cost_charged,
    'additional_pending_amount',coalesce((select sum(amount) from public.settlement_box_cost_adjustments where shipment_id=p_shipment_id and status='pending'),0));
end;
$$;
revoke all on function public.admin_update_shipment_box_count(bigint,integer,integer) from public,anon;
grant execute on function public.admin_update_shipment_box_count(bigint,integer,integer) to authenticated;

-- 확인한 행별 금액과 현재 원장을 비교한 후 일반 정산·추가 지급을 원자적으로 완료한다.
create function public.admin_complete_settlement_payouts(p_rows jsonb,p_transfer_reference text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_ids bigint[]; v_base_ids bigint[]; v_result jsonb; v_extra jsonb; v_count integer;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)=0 then raise exception '정산 대상을 선택해 주세요.'; end if;
  select array_agg(id),count(distinct id) into v_ids,v_count from jsonb_to_recordset(p_rows) as x(id bigint,net_amount integer);
  if v_count<>jsonb_array_length(p_rows) then raise exception '정산 대상이 중복되거나 잘못되었습니다.'; end if;
  perform sh.id from public.shipments sh where sh.id in (
    select b.shipment_id from public.settlements st join public.books b on b.id=st.book_id where st.id=any(v_ids)
    union select a.shipment_id from public.settlement_box_cost_adjustments a where a.id=any(v_ids)
  ) order by sh.id for update;
  perform id from public.settlements where id=any(v_ids) order by id for update;
  perform id from public.settlement_box_cost_adjustments where id=any(v_ids) order by id for update;
  if exists(select 1 from jsonb_to_recordset(p_rows) as x(id bigint,net_amount integer)
    left join public.settlement_payout_rows st on st.id=x.id
    where st.id is null or st.status not in ('pending','approved') or st.net_amount is distinct from x.net_amount) then
    raise exception '정산 금액 또는 지급 상태가 변경됐습니다. 새로고침 후 이체 내역과 다시 확인해 주세요.';
  end if;
  -- 추가 지급도 원래 주문의 미해소 환불·회수는 보류한다.
  if exists(select 1 from public.settlement_box_cost_adjustments a
    join public.settlements st on st.id=a.reference_settlement_id left join public.orders o on o.id=st.order_id
    where a.id=any(v_ids) and (st.status<>'completed'
      or (o.refund_requested_at is not null and o.refund_request_resolved_at is null)
      or exists(select 1 from public.order_return_cases rc where rc.order_id=st.order_id and rc.status not in ('refunded','cancelled')))) then
    raise exception '환불·회수 처리 중인 추가 지급 건이 있습니다.';
  end if;
  select coalesce(array_agg(id),'{}'::bigint[]) into v_base_ids from public.settlements where id=any(v_ids);
  v_result:=public.admin_complete_settlements(v_base_ids,p_transfer_reference);
  if coalesce((v_result->>'updated_count')::integer,0)<>cardinality(v_base_ids) then
    raise exception '정산계좌를 확인한 뒤 다시 처리해 주세요.';
  end if;
  -- 추가 지급은 원정산의 계좌 스냅샷을 사용한다. 평문 계좌를 새 테이블에 복제하지 않는다.
  if exists(select 1 from public.settlement_box_cost_adjustments a join public.settlements st on st.id=a.reference_settlement_id
    where a.id=any(v_ids) and (nullif(btrim(st.bank_name),'') is null or nullif(btrim(st.account_holder),'') is null
      or (st.account_number_ciphertext is null and nullif(btrim(st.account_number),'') is null))) then
    raise exception '추가 지급 계좌를 확인해 주세요.';
  end if;
  update public.settlement_box_cost_adjustments set status='completed',completed_at=now(),updated_at=now(),
    transfer_reference=nullif(btrim(p_transfer_reference),'') where id=any(v_ids) and status='pending';
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'seller_user_id',sh.user_id,
    'seller_name',coalesce(nullif(btrim(mp.name),''),sh.seller_name),'seller_phone',coalesce(nullif(btrim(mp.phone),''),sh.seller_phone),
    'net_amount',a.amount,'bank_name',st.bank_name,'account_last4',coalesce(st.account_number_last4,public.get_account_last4(st.account_number)),
    'status',a.status,'completed_at',a.completed_at,'book_title','상품화 비용 조정 (추가 지급)','transfer_reference',a.transfer_reference)),'[]')
    into v_extra from public.settlement_box_cost_adjustments a join public.settlements st on st.id=a.reference_settlement_id
    join public.shipments sh on sh.id=a.shipment_id left join public.member_profiles mp on mp.user_id=sh.user_id where a.id=any(v_ids);
  return v_result||jsonb_build_object('updated_count',v_count,'completed_count',v_count,
    'settlements',coalesce(v_result->'settlements','[]')||v_extra);
end;
$$;
revoke all on function public.admin_complete_settlement_payouts(jsonb,text) from public,anon;
grant execute on function public.admin_complete_settlement_payouts(jsonb,text) to authenticated;
-- 이전 화면은 새로고침 후 금액 검증이 있는 새 진입점을 사용한다.
revoke execute on function public.admin_complete_settlements(bigint[],text) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.list_admin_settlements(p_statuses text[] DEFAULT NULL::text[], p_search text DEFAULT NULL::text, p_from_date date DEFAULT NULL::date, p_to_date date DEFAULT NULL::date, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result jsonb;
  v_kst_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  with filtered as (
    select
      st.*,
      o.order_number,
      o.confirmed_at,
      oi.quantity,
      case when st.sale_source='box_cost_adjustment' then '상품화 비용 조정 (추가 지급)' else coalesce(oi.title, b.title) end as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.condition_grade, b.condition_grade) as condition_grade,
      b.shipment_id,
      sh.seller_name as shipment_seller_name,
      sh.seller_phone as shipment_seller_phone,
      mp.email as seller_email,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as seller_phone,
      -- 계좌 해석: settlement 스냅샷 → 셀러 현재 기본계좌 → 비회원 셀러 shipments 스냅샷
      -- (지급 롤업·완료 RPC와 동일 규칙)
      coalesce(
        nullif(btrim(st.bank_name), ''),
        acc.bank_name,
        nullif(btrim(sh.settlement_bank_name), '')
      ) as resolved_bank_name,
      coalesce(
        nullif(btrim(st.account_holder), ''),
        acc.account_holder,
        nullif(btrim(sh.settlement_account_holder), '')
      ) as resolved_account_holder,
      coalesce(
        st.account_number_ciphertext,
        acc.account_number_ciphertext,
        sh.settlement_account_number_ciphertext
      ) as resolved_ciphertext,
      coalesce(
        st.account_number_last4,
        public.get_account_last4(st.account_number),
        acc.account_number_last4,
        public.get_account_last4(acc.account_number),
        sh.settlement_account_last4
      ) as resolved_last4
    from public.settlement_payout_rows st
    left join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.member_profiles mp
      on mp.user_id = st.seller_user_id
    left join lateral (
      select
        msa.bank_name,
        msa.account_number,
        msa.account_number_ciphertext,
        msa.account_number_last4,
        msa.account_holder
      from public.member_settlement_accounts msa
      where msa.user_id = st.seller_user_id
      order by msa.is_default desc, msa.created_at desc, msa.id desc
      limit 1
    ) acc on true
    where
      (coalesce(cardinality(p_statuses), 0) = 0 or st.status = any(p_statuses))
      and (p_from_date is null or st.scheduled_date >= p_from_date)
      and (p_to_date is null or st.scheduled_date <= p_to_date)
      and (
        nullif(btrim(coalesce(p_search, '')), '') is null
        or o.order_number ilike '%' || btrim(p_search) || '%'
        or coalesce(oi.title, b.title) ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.name, sh.seller_name, '') ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.email, '') ilike '%' || btrim(p_search) || '%'
        or coalesce(mp.phone, sh.seller_phone, '') ilike '%' || btrim(p_search) || '%'
      )
  ),
  page_rows as (
    select *
    from filtered
    order by
      case status when 'pending' then 1 when 'approved' then 2 else 3 end,
      scheduled_date asc,
      id desc
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 100), 500))
  )
  select jsonb_build_object(
    'rows',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', row_data.id,
            'sale_source', row_data.sale_source,
            'box_cost_deducted', row_data.box_cost_deducted,
            'seller_user_id', row_data.seller_user_id,
            'seller_name', coalesce(row_data.seller_name, '판매자 미연결'),
            'seller_email', row_data.seller_email,
            'seller_phone', row_data.seller_phone,
            'order_id', row_data.order_id,
            'order_number', row_data.order_number,
            'order_item_id', row_data.order_item_id,
            'book_id', row_data.book_id,
            'book_title', row_data.book_title,
            'book_option', row_data.book_option,
            'condition_grade', row_data.condition_grade,
            'shipment_id', row_data.shipment_id,
            'sale_amount', row_data.sale_amount,
            'fee_percent', row_data.fee_percent,
            'fee_amount', row_data.fee_amount,
            'net_amount', row_data.net_amount,
            'status', row_data.status,
            'scheduled_date', row_data.scheduled_date,
            'approved_at', row_data.approved_at,
            'completed_at', row_data.completed_at,
            'bank_name', row_data.resolved_bank_name,
            -- 어드민 마스킹 해제(2026-07-24): 복호화 실번호 우선, 암호문 없으면 마스킹 폴백
            'account_number', coalesce(
              public.decrypt_account_number(row_data.resolved_ciphertext),
              public.mask_account_number(row_data.resolved_last4)
            ),
            'account_holder', row_data.resolved_account_holder,
            'account_last4', row_data.resolved_last4,
            'confirmed_at', row_data.confirmed_at,
            'created_at', row_data.created_at,
            'updated_at', row_data.updated_at
          )
          order by
            case row_data.status when 'pending' then 1 when 'approved' then 2 else 3 end,
            row_data.scheduled_date asc,
            row_data.id desc
        )
        from page_rows row_data
      ),
      '[]'::jsonb
    ),
    'total_count', (select count(*) from filtered),
    'summary',
    jsonb_build_object(
      'pending_count', (select count(*) from filtered where status = 'pending'),
      'approved_count', (select count(*) from filtered where status = 'approved'),
      'completed_count', (select count(*) from filtered where status = 'completed'),
      'pending_amount', coalesce((select sum(net_amount) from filtered where status = 'pending'), 0),
      'approved_amount', coalesce((select sum(net_amount) from filtered where status = 'approved'), 0),
      'completed_amount', coalesce((select sum(net_amount) from filtered where status = 'completed'), 0),
      -- 승인 단계 폐지: '오늘 지급 필요' = 미지급(pending+approved) 중 지급일 도래분 (KST)
      'due_pending_count', (select count(*) from filtered where status in ('pending', 'approved') and scheduled_date <= v_kst_today),
      'due_pending_amount', coalesce((select sum(net_amount) from filtered where status in ('pending', 'approved') and scheduled_date <= v_kst_today), 0)
    )
  )
  into v_result;

  return v_result;
end;
$function$;


CREATE OR REPLACE FUNCTION public.get_my_settlements(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  with platform_rows as (
    select
      st.*,
      o.order_number,
      coalesce(st.manual_sold_at, o.created_at) as sold_at,
      o.confirmed_at as order_confirmed_at,
      case when st.sale_source='box_cost_adjustment' then '상품화 비용 조정 (추가 지급)' else coalesce(oi.title, b.title) end as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.quantity, 1) as quantity,
      b.shipment_id,
      pr.request_number as pickup_request_number
    from public.settlement_payout_rows st
    left join public.orders o
      on o.id = st.order_id
    left join public.order_items oi
      on oi.id = st.order_item_id
    join public.books b
      on b.id = st.book_id
    left join public.shipments sh
      on sh.id = b.shipment_id
    left join public.pickup_requests pr
      on pr.id = sh.pickup_request_id
    where st.seller_user_id = v_user_id
      -- 취소(환불·수동정산 대체)/회수 대상은 셀러 목록에서 제외
      -- (프론트는 completed 외 전부 '정산 예정'으로 렌더하므로 새면 안 됨)
      and st.status in ('pending', 'approved', 'completed')
  ),
  -- 구 수북(식스샵) 판매분 수동정산 — shipment 소유자 기준으로 본인 것만
  manual_rows as (
    select
      ms.id,
      ms.book_id,
      b.title as book_title,
      b.option as book_option,
      ms.shipment_id,
      ms.sale_amount,
      ms.fee_percent,
      ms.fee_amount,
      ms.net_amount,
      case when ms.status = 'paid' then 'completed' else 'pending' end as status,
      ms.paid_at,
      ms.sold_at,
      ms.created_at
    from public.manual_settlements ms
    join public.shipments s
      on s.id = ms.shipment_id
    left join public.books b
      on b.id = ms.book_id
    where s.user_id = v_user_id
      and ms.status <> 'cancelled'
  ),
  combined as (
    select
      jsonb_build_object(
        'id', row_data.id,
        'source', case when row_data.sale_source='box_cost_adjustment' then 'box_cost_adjustment' when row_data.sale_source = 'manual_sale' then 'manual' else 'platform' end,
        'order_id', row_data.order_id,
        'order_number', row_data.order_number,
        'book_id', row_data.book_id,
        'book_title', row_data.book_title,
        'book_option', row_data.book_option,
        'book_count', case when row_data.sale_source='box_cost_adjustment' then 0 else greatest(1, coalesce(row_data.quantity, 1)) end,
        -- 셀러가 아는 요청번호(PU-xxxx) 우선, 브리지 안 된 레거시는 shipment_id 유지
        'pickup_reference', coalesce(row_data.pickup_request_number, row_data.shipment_id::text),
        'sale_amount', row_data.sale_amount,
        'fee_percent', row_data.fee_percent,
        'fee_amount', row_data.fee_amount,
        'box_cost_deducted', coalesce(row_data.box_cost_deducted, 0),
        'net_amount', row_data.net_amount,
        'status', row_data.status,
        'scheduled_date', row_data.scheduled_date,
        'approved_at', row_data.approved_at,
        'completed_at', row_data.completed_at,
        'sold_at', row_data.sold_at,
        'confirmed_at', row_data.order_confirmed_at,
        'bank_name', row_data.bank_name,
        'account_number', public.mask_account_number(coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number))),
        'account_holder', row_data.account_holder,
        'account_last4', coalesce(row_data.account_number_last4, public.get_account_last4(row_data.account_number)),
        'created_at', row_data.created_at
      ) as row_json,
      case row_data.status when 'completed' then 1 when 'approved' then 2 else 3 end as status_rank,
      coalesce(row_data.completed_at, row_data.scheduled_date::timestamptz, row_data.created_at) as sort_ts,
      row_data.id::text as sort_id
    from platform_rows row_data

    union all

    select
      jsonb_build_object(
        'id', 'manual-' || mr.id::text,
        'source', 'manual',
        'order_id', null,
        'order_number', null,
        'book_id', mr.book_id,
        'book_title', mr.book_title,
        'book_option', mr.book_option,
        'book_count', 1,
        'pickup_reference', mr.shipment_id::text,
        'sale_amount', mr.sale_amount,
        'fee_percent', mr.fee_percent,
        'fee_amount', mr.fee_amount,
        'box_cost_deducted', 0,
        'net_amount', mr.net_amount,
        'status', mr.status,
        'scheduled_date', null,
        'approved_at', null,
        'completed_at', mr.paid_at,
        'sold_at', mr.sold_at,
        'confirmed_at', null,
        'bank_name', null,
        'account_number', null,
        'account_holder', null,
        'account_last4', null,
        'created_at', mr.created_at
      ) as row_json,
      case mr.status when 'completed' then 1 else 3 end as status_rank,
      coalesce(mr.paid_at, mr.created_at) as sort_ts,
      'manual-' || mr.id::text as sort_id
    from manual_rows mr
  ),
  all_my_settlements as (
    select status, net_amount, completed_at
    from public.settlement_payout_rows
    where seller_user_id = v_user_id
    union all
    select status, net_amount, paid_at as completed_at
    from manual_rows
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(page.row_json order by page.status_rank, page.sort_ts desc nulls last, page.sort_id desc)
          from (
            select row_json, status_rank, sort_ts, sort_id
            from combined
            order by status_rank, sort_ts desc nulls last, sort_id desc
            offset greatest(0, coalesce(p_offset, 0))
            limit greatest(1, least(coalesce(p_limit, 50), 200))
          ) page
        ),
        '[]'::jsonb
      ),
    'summary',
      jsonb_build_object(
        'current_month_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status = 'completed'
              and completed_at >= date_trunc('month', now())
          ), 0),
        'total_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status = 'completed'
          ), 0),
        'expected_amount',
          coalesce((
            select sum(net_amount)
            from all_my_settlements
            where status in ('pending', 'approved')
          ), 0),
        'pending_count',
          (select count(*) from all_my_settlements where status = 'pending'),
        'approved_count',
          (select count(*) from all_my_settlements where status = 'approved'),
        'completed_count',
          (select count(*) from all_my_settlements where status = 'completed')
      )
  )
  into v_result;

  return v_result;
end;
$function$;


CREATE OR REPLACE FUNCTION public.notify_slack_settlement_due()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_url text;
  v_kst_today date := (now() at time zone 'Asia/Seoul')::date;
  v_count integer;
  v_total bigint;
  v_lines text;
  v_extra_count integer;
  v_extra_amount bigint;
  -- 정산 담당 태그 대상: 박영제 (subook.slack.com 멤버 ID)
  v_mention constant text := '<@U0B7ELQCLAV>';
begin
  select count(*)::integer, coalesce(sum(net_amount), 0)::bigint
    into v_count, v_total
  from public.settlement_payout_rows
  where status in ('pending', 'approved')
    and scheduled_date <= v_kst_today;

  -- 지급할 게 없는 날은 침묵 (매일 도는 크론이지만 도래 건이 있을 때만 발송)
  if coalesce(v_count, 0) = 0 then
    return jsonb_build_object('sent', false, 'reason', 'no_due');
  end if;

  -- ⚠ notify_ops_slack 금지 — 그쪽은 slack_sys_webhook_url(시스템 경보 프라이빗
  --   채널) 우선이라, 팀 채널용 시크릿을 직접 읽는다 (주문/수거 알림과 동일).
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    return jsonb_build_object('sent', false, 'reason', 'no_webhook');
  end if;

  -- 셀러 단위 롤업 (금액 큰 순 상위 10명 + 나머지 합산 한 줄)
  with grouped as (
    select
      coalesce(
        max(nullif(btrim(mp.name), '')),
        max(nullif(btrim(sh.seller_name), '')),
        '판매자 미연결'
      ) as seller_name,
      count(*)::integer as cnt,
      sum(st.net_amount)::bigint as amt
    from public.settlement_payout_rows st
    left join public.member_profiles mp on mp.user_id = st.seller_user_id
    left join public.books b on b.id = st.book_id
    left join public.shipments sh on sh.id = b.shipment_id
    where st.status in ('pending', 'approved')
      and st.scheduled_date <= v_kst_today
    group by st.seller_user_id
  ),
  numbered as (
    select *, row_number() over (order by amt desc, seller_name) as rn
    from grouped
  )
  select
    string_agg(
      format('· %s — %s건 · %s원', seller_name, cnt, to_char(amt, 'FM999,999,999,999')),
      E'\n' order by rn
    ) filter (where rn <= 10),
    count(*) filter (where rn > 10),
    coalesce(sum(amt) filter (where rn > 10), 0)
  into v_lines, v_extra_count, v_extra_amount
  from numbered;

  if coalesce(v_extra_count, 0) > 0 then
    v_lines := v_lines || format(E'\n… 외 %s명 · %s원', v_extra_count, to_char(v_extra_amount, 'FM999,999,999,999'));
  end if;

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object('attachments', jsonb_build_array(jsonb_build_object(
      'color', '#F2C744',
      'fallback', format('정산 리마인더 — %s건 · %s원 지급 대기', v_count, to_char(v_total, 'FM999,999,999,999')),
      'blocks', jsonb_build_array(
        jsonb_build_object('type', 'header', 'text', jsonb_build_object(
          'type', 'plain_text', 'text', format('💸 오늘 지급할 정산 %s건', v_count))),
        jsonb_build_object('type', 'section', 'text', jsonb_build_object(
          'type', 'mrkdwn', 'text',
          format(E'%s 지급일이 도래한 정산 *%s건 · 총 %s원*입니다.\n송금 후 어드민에서 정산 완료 처리해주세요.',
            v_mention, v_count, to_char(v_total, 'FM999,999,999,999')))),
        jsonb_build_object('type', 'section', 'text', jsonb_build_object(
          'type', 'mrkdwn', 'text', v_lines)),
        jsonb_build_object('type', 'section', 'text', jsonb_build_object(
          'type', 'mrkdwn', 'text',
          '<https://admin.subook.kr/admin/settlements|어드민에서 정산 처리 →>'))
      )
    )))
  );

  return jsonb_build_object('sent', true, 'due_count', v_count, 'due_amount', v_total);
end;
$function$;


