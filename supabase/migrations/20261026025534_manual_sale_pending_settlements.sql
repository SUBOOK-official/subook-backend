-- 수동 판매도 기존 지급 원장에 정산대기를 만든다. 결제/주문은 생성하지 않는다.
-- 기존 행·RLS·금액·지급 RPC는 보존한다. 주문 없는 행은 manual_sale만 허용한다.
-- 공식 문서: https://supabase.com/docs/guides/database/functions
-- 롤백: 버튼/함수를 이전 버전으로 복원하되 생성된 정산·비용 차감 원장은 보존한다.
begin;

alter table public.settlements
  add column sale_source text not null default 'order',
  add column manual_sold_at timestamptz,
  alter column order_id drop not null;
alter table public.settlements add constraint settlements_sale_source_check check (
  (sale_source = 'order' and order_id is not null and manual_sold_at is null)
  or (sale_source = 'manual_sale' and order_id is null and order_item_id is null and manual_sold_at is not null)
);
create unique index settlements_manual_sale_book_unique
  on public.settlements(book_id) where sale_source = 'manual_sale' and status <> 'cancelled';
comment on column public.settlements.sale_source is 'order=플랫폼 주문, manual_sale=관리자 권별 판매완료. 동일 지급 원장/RLS 사용.';

create or replace function public.admin_mark_book_sold(p_book_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_book public.books%rowtype;
  v_shipment public.shipments%rowtype;
  v_account public.member_settlement_accounts%rowtype;
  v_existing public.settlements%rowtype;
  v_settlement_id bigint;
  v_fee_percent numeric;
  v_fee_amount integer;
  v_net_pre integer;
  v_box_deduct integer;
  v_sold_at timestamptz := now();
  v_already_sold boolean;
begin
  if not public.is_admin_user() then
    raise exception '관리자만 판매완료 처리할 수 있습니다.' using errcode = '42501';
  end if;
  select * into v_book from public.books where id = p_book_id for update;
  if not found then raise exception '교재를 찾을 수 없습니다.'; end if;
  if v_book.status is null or v_book.status not in ('on_sale', 'settled') or v_book.condition_grade = 'DISCARD' then
    raise exception '판매중인 교재만 수동으로 판매완료 처리할 수 있습니다.';
  end if;
  v_already_sold := v_book.status = 'settled';

  if exists (
    select 1 from public.order_items oi join public.orders o on o.id = oi.order_id
    where oi.book_id = p_book_id and oi.refunded_at is null and o.status not in ('cancelled', 'refunded')
  ) then
    raise exception '진행 중인 주문이 있는 교재입니다. 주문 화면에서 처리해 주세요.';
  end if;

  select * into v_existing from public.settlements
    where book_id = p_book_id and sale_source = 'manual_sale' and status <> 'cancelled'
    order by id desc limit 1;
  if found then
    return jsonb_build_object('book_id', p_book_id, 'already_sold', v_already_sold,
      'settlement_created', false, 'settlement_id', v_existing.id,
      'settlement_status', v_existing.status, 'net_amount', v_existing.net_amount,
      'scheduled_date', v_existing.scheduled_date);
  end if;
  -- 기존/취소된 정산을 임의로 덮거나 재생성하지 않는다. 누락된 판매완료 건만 보완한다.
  if exists(select 1 from public.settlements where book_id = p_book_id)
    or exists(select 1 from public.manual_settlements where book_id = p_book_id) then
    raise exception '이미 정산 이력이 있는 교재입니다. 기존 정산 내역을 확인해 주세요.';
  end if;

  if v_book.shipment_id is not null then
    -- 자동 정산과 같은 수거 행 잠금: 상품화 비용은 수거별 잔액만 한 번 차감한다.
    select * into v_shipment from public.shipments where id = v_book.shipment_id for update;
    if not found then raise exception '수거 정보를 찾을 수 없습니다.'; end if;
  end if;
  if v_book.shipment_id is null or coalesce(v_shipment.is_direct_purchase, false) then
    update public.books set status = 'settled', is_public = false where id = p_book_id;
    return jsonb_build_object('book_id', p_book_id, 'already_sold', v_already_sold,
      'settlement_created', false, 'settlement_excluded', 'direct_purchase');
  end if;
  if v_book.price is null or v_book.price <= 0 then
    raise exception '정산을 생성하려면 1원 이상의 판매가가 필요합니다.';
  end if;

  v_fee_percent := public.calculate_settlement_fee_percent(v_book.price, v_shipment.pickup_date, v_shipment.fee_policy_version);
  v_fee_amount := round(v_book.price * (v_fee_percent / 100))::integer;
  v_net_pre := v_book.price - v_fee_amount;
  v_box_deduct := least(v_net_pre, greatest(0, coalesce(v_shipment.box_count, 0) * 5000 - coalesce(v_shipment.box_cost_charged, 0)));
  select * into v_account from public.member_settlement_accounts
    where user_id = v_shipment.user_id order by is_default desc, created_at desc, id desc limit 1;

  insert into public.settlements (
    seller_user_id, book_id, sale_source, manual_sold_at,
    sale_amount, fee_percent, fee_amount, net_amount, box_cost_deducted, status, scheduled_date,
    bank_name, account_number, account_number_ciphertext, account_number_last4, account_holder
  ) values (
    v_shipment.user_id, p_book_id, 'manual_sale', v_sold_at,
    v_book.price, v_fee_percent, v_fee_amount, v_net_pre - v_box_deduct, v_box_deduct, 'pending', public.next_settlement_date(v_sold_at),
    coalesce(v_account.bank_name, v_shipment.settlement_bank_name),
    public.mask_account_number(coalesce(v_account.account_number_last4, public.get_account_last4(v_account.account_number), v_shipment.settlement_account_last4)),
    coalesce(v_account.account_number_ciphertext, v_shipment.settlement_account_number_ciphertext),
    coalesce(v_account.account_number_last4, public.get_account_last4(v_account.account_number), v_shipment.settlement_account_last4),
    coalesce(v_account.account_holder, v_shipment.settlement_account_holder)
  ) returning id into v_settlement_id;
  if v_box_deduct > 0 then
    update public.shipments set box_cost_charged = coalesce(box_cost_charged, 0) + v_box_deduct where id = v_book.shipment_id;
  end if;
  update public.books set status = 'settled', is_public = false where id = p_book_id;
  return jsonb_build_object('book_id', p_book_id, 'already_sold', v_already_sold,
    'settlement_created', true, 'settlement_id', v_settlement_id, 'settlement_status', 'pending',
    'net_amount', v_net_pre - v_box_deduct, 'scheduled_date', public.next_settlement_date(v_sold_at));
end;
$$;
revoke all on function public.admin_mark_book_sold(bigint) from public, anon;
grant execute on function public.admin_mark_book_sold(bigint) to authenticated, service_role;

-- 레거시 엑셀 정산도 같은 교재 잠금을 사용해 두 경로의 동시 생성/이중 지급을 막는다.
create or replace function public.manual_settlements_guard_manual_sale()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status <> 'cancelled' then
    perform 1 from public.books where id = new.book_id for update;
    if exists(select 1 from public.settlements where book_id = new.book_id and sale_source = 'manual_sale' and status <> 'cancelled') then
      raise exception '수동 판매완료 정산이 이미 존재합니다. 기존 정산 내역을 확인해 주세요.';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.manual_settlements_guard_manual_sale() from public, anon, authenticated;
create trigger manual_settlements_guard_manual_sale_trigger
  before insert or update of book_id, status on public.manual_settlements
  for each row execute function public.manual_settlements_guard_manual_sale();

-- 조회/주문 정산 함수는 아래에서 현재 운영 정의를 최소 변경한다.
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
      coalesce(oi.title, b.title) as book_title,
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
    from public.settlements st
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
      coalesce(oi.title, b.title) as book_title,
      coalesce(oi.option_label, b.option) as book_option,
      coalesce(oi.quantity, 1) as quantity,
      b.shipment_id,
      pr.request_number as pickup_request_number
    from public.settlements st
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
        'source', case when row_data.sale_source = 'manual_sale' then 'manual' else 'platform' end,
        'order_id', row_data.order_id,
        'order_number', row_data.order_number,
        'book_id', row_data.book_id,
        'book_title', row_data.book_title,
        'book_option', row_data.book_option,
        'book_count', greatest(1, coalesce(row_data.quantity, 1)),
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
    from public.settlements
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

CREATE OR REPLACE FUNCTION public.create_settlements_for_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order record;
  v_item record;
  v_unit_price integer;
  v_sale_amount integer;
  v_fee_percent numeric(5, 2);
  v_fee_amount integer;
  v_net_pre integer;
  v_box_cost_per_box constant integer := 5000;
  v_box_count integer;
  v_box_charged integer;
  v_box_remaining integer;
  v_box_deduct integer;
  v_net_amount integer;
  v_inserted_count integer := 0;
begin
  select * into v_order
    from public.orders
   where id = p_order_id
     and status = 'confirmed'
     and confirmed_at is not null for update;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'order_not_confirmed');
  end if;

  if (v_order.refund_requested_at is not null and v_order.refund_request_resolved_at is null)
    or exists(select 1 from public.order_return_cases where order_id=p_order_id and status not in ('refunded','cancelled')) then
    return jsonb_build_object('success',false,'reason','refund_on_hold');
  end if;

  for v_item in
    select
      oi.id        as order_item_id,
      oi.book_id,
      oi.quantity,
      oi.unit_price,
      oi.total_price,
      b.shipment_id,
      s.user_id    as seller_user_id,
      s.pickup_date,
      s.fee_policy_version,
      coalesce(s.is_direct_purchase, false) as is_direct_purchase,
      -- 계좌 해석: 회원 셀러는 기본 정산계좌, 비회원 셀러는 shipments 스냅샷
      coalesce(msa.bank_name, s.settlement_bank_name) as bank_name,
      coalesce(msa.account_number_ciphertext, s.settlement_account_number_ciphertext)
        as account_number_ciphertext,
      coalesce(
        msa.account_number_last4,
        public.get_account_last4(msa.account_number),
        s.settlement_account_last4
      ) as account_number_last4,
      coalesce(msa.account_holder, s.settlement_account_holder) as account_holder
    from public.order_items oi
    join public.books b
      on b.id = oi.book_id
    left join public.shipments s
      on s.id = b.shipment_id
    left join lateral (
      select
        account.bank_name,
        account.account_number,
        account.account_number_ciphertext,
        account.account_number_last4,
        account.account_holder
      from public.member_settlement_accounts account
      where account.user_id = s.user_id
      order by account.is_default desc, account.created_at desc, account.id desc
      limit 1
    ) msa on true
    where oi.order_id = p_order_id
      -- ⚠ 부분환불된 품목은 정산 생성 제외 (2026-08-01 품목별 부분환불 도입)
      and oi.refunded_at is null
      -- ⚠ 수동정산(엑셀)으로 지급 추적 중인 책은 자동 정산 생성 제외
      --   (2026-08-09 수동 우선 정책 — 엑셀 지급 후 자동 구매확정 시 중복 방지)
      and not exists (
        select 1
        from public.manual_settlements ms
        where ms.book_id = oi.book_id
          and ms.status <> 'cancelled'
      )
      -- 수동 판매완료로 정산 예정/지급 기록이 있으면 자동 정산을 중복 생성하지 않는다.
      and not exists (
        select 1 from public.settlements st
        where st.book_id = oi.book_id and st.sale_source = 'manual_sale' and st.status <> 'cancelled'
      )
  loop
    -- 지급할 셀러가 없는 재고만 제외한다 (2026-09-01):
    --   · shipment_id IS NULL  = 자체판매(직접 매입·출판사 직거래) 재고
    --   · is_direct_purchase   = 자체매입 버킷 수거건
    -- 셀러 회원 미연결(seller_user_id IS NULL)은 비회원 위탁 셀러이므로 정산 대상이다.
    if v_item.shipment_id is null or v_item.is_direct_purchase then
      continue;
    end if;

    v_sale_amount := greatest(
      0,
      coalesce(v_item.total_price,
               v_item.unit_price * greatest(1, coalesce(v_item.quantity, 1)),
               0)
    );
    if v_sale_amount <= 0 then
      continue;
    end if;

    v_unit_price := greatest(
      0,
      coalesce(
        v_item.unit_price,
        case
          when coalesce(v_item.quantity, 0) > 0
            then floor(v_sale_amount::numeric / v_item.quantity)::integer
          else v_sale_amount
        end,
        0
      )
    );

    v_fee_percent := public.calculate_settlement_fee_percent(v_unit_price, v_item.pickup_date, v_item.fee_policy_version);
    v_fee_amount := round(v_sale_amount * (v_fee_percent / 100))::integer;

    v_net_pre := v_sale_amount - v_fee_amount;
    if v_net_pre <= 0 then
      raise notice 'create_settlements_for_order: net_amount<=0 skip order=% book=%',
        p_order_id, v_item.book_id;
      continue;
    end if;

    -- 박스당 상품화 비용 차감 (shipment 단위, 첫 정산부터 차감 + 이월).
    -- shipment 행을 잠가 동일 수거의 여러 책/동시 정산이 같은 box_cost_charged를 두 번 읽는 것을 방지.
    v_box_deduct := 0;
    v_net_amount := v_net_pre;
    if v_item.shipment_id is not null then
      select coalesce(box_count, 0), coalesce(box_cost_charged, 0)
        into v_box_count, v_box_charged
        from public.shipments
       where id = v_item.shipment_id
       for update;
      v_box_remaining := greatest(0, (v_box_count * v_box_cost_per_box) - v_box_charged);
      v_box_deduct := least(v_box_remaining, v_net_pre);
      v_net_amount := v_net_pre - v_box_deduct;
    end if;

    insert into public.settlements (
      seller_user_id, order_id, order_item_id, book_id,
      sale_amount, fee_percent, fee_amount, net_amount, box_cost_deducted,
      status, scheduled_date,
      bank_name, account_number, account_number_ciphertext, account_number_last4, account_holder
    )
    values (
      v_item.seller_user_id, p_order_id, v_item.order_item_id, v_item.book_id,
      v_sale_amount, v_fee_percent, v_fee_amount, v_net_amount, v_box_deduct,
      'pending',
      public.next_settlement_date(v_order.confirmed_at),
      v_item.bank_name,
      public.mask_account_number(v_item.account_number_last4),
      v_item.account_number_ciphertext,
      v_item.account_number_last4,
      v_item.account_holder
    )
    on conflict (order_id, book_id) do nothing;

    if found then
      v_inserted_count := v_inserted_count + 1;
      -- 차감은 settlement가 실제로 새로 생성된 경우에만 누적(재실행 중복차감 방지).
      if v_box_deduct > 0 then
        update public.shipments
          set box_cost_charged = coalesce(box_cost_charged, 0) + v_box_deduct
          where id = v_item.shipment_id;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'inserted_count', v_inserted_count
  );
end;
$function$;

commit;
