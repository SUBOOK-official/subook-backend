-- 배포 1단계: 기존 수거/정산은 변경하지 않고 정책 스냅샷 경로만 준비한다.
-- 활성화는 public/admin/seller 배포 검증 후 별도 migration으로 수행한다.
begin;

create table public.pickup_fee_policy_releases (
  version text primary key check (version = '2026-09'),
  activated_at timestamptz not null default clock_timestamp()
);
alter table public.pickup_fee_policy_releases enable row level security;
revoke all on public.pickup_fee_policy_releases from anon, authenticated;
-- 정책 활성화 원장은 서버 전용. 기존 수거/입고 RLS는 그대로 유지한다.

alter table public.pickup_requests add column fee_policy_version text
  check (fee_policy_version is null or fee_policy_version = '2026-09');
alter table public.shipments add column fee_policy_version text
  check (fee_policy_version is null or fee_policy_version = '2026-09');
comment on column public.pickup_requests.fee_policy_version is
  '접수 시 고정한 수수료 정책. NULL은 인상 전 정책이며 소급 변경 금지.';
comment on column public.shipments.fee_policy_version is
  '수거 신청에서 승계한 수수료 정책. NULL은 인상 전 정책이며 입고/판매일로 재판정하지 않는다.';

create function public.snapshot_pickup_fee_policy()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_active_at timestamptz;
  v_linked_version text;
begin
  if tg_op = 'UPDATE' then
    -- 날짜 수정, 재접수, 회원 연결로 기존 수거의 수수료가 바뀌면 안 된다.
    if new.fee_policy_version is distinct from old.fee_policy_version then
      raise exception '접수 시 확정된 수수료 정책은 변경할 수 없습니다.';
    end if;
    if tg_table_name = 'pickup_requests' then
      if new.merged_into_id is distinct from old.merged_into_id and new.merged_into_id is not null then
        select fee_policy_version into v_linked_version from public.pickup_requests where id = new.merged_into_id;
        if new.fee_policy_version is distinct from v_linked_version then
          raise exception '수수료 정책이 다른 수거 신청은 병합할 수 없습니다.';
        end if;
      end if;
    else
      if new.pickup_request_id is distinct from old.pickup_request_id and new.pickup_request_id is not null then
        select root.fee_policy_version into v_linked_version
        from public.pickup_requests pr join public.pickup_requests root on root.id = coalesce(pr.merged_into_id, pr.id)
        where pr.id = new.pickup_request_id;
        if new.fee_policy_version is distinct from v_linked_version then
          raise exception '수수료 정책이 다른 수거 신청에는 연결할 수 없습니다. 해당 신청에서 검수를 시작해 주세요.';
        end if;
      end if;
    end if;
    return new;
  end if;

  select activated_at into v_active_at from public.pickup_fee_policy_releases where version = '2026-09';
  new.fee_policy_version := null;
  if tg_table_name = 'pickup_requests' then
    if v_active_at is not null and clock_timestamp() >= v_active_at then
      if current_setting('subook.pickup_fee_consent', true) is distinct from '2026-09' then
        raise exception '수수료 정책이 변경되었습니다. 새로고침 후 새 약관을 확인하고 다시 신청해 주세요.';
      end if;
      new.fee_policy_version := '2026-09';
    end if;
  elsif new.pickup_request_id is not null then
    -- 배포 전 신청 + 배포 후 입고: 신청 당시 정책(NULL)을 그대로 승계한다.
    select root.fee_policy_version into new.fee_policy_version
    from public.pickup_requests pr join public.pickup_requests root on root.id = coalesce(pr.merged_into_id, pr.id)
    where pr.id = new.pickup_request_id;
  elsif v_active_at is not null and clock_timestamp() >= v_active_at
      and current_setting('subook.direct_pickup_new_policy', true) = 'true' then
    -- 오프라인 수거는 운영자가 접수 시점을 확인해야 한다. 옛 클라이언트/미확인 건은 기존 요율.
    if new.pickup_date < (v_active_at at time zone 'Asia/Seoul')::date then
      raise exception '인상 전 수거일에는 신규 수수료를 적용할 수 없습니다.';
    end if;
    if exists (
      select 1 from public.pickup_requests pr
      where pr.fee_policy_version is null and pr.status <> 'cancelled' and pr.merged_into_id is null
        and regexp_replace(pr.pickup_recipient_name, '\s', '', 'g') = regexp_replace(new.seller_name, '\s', '', 'g')
        and regexp_replace(pr.pickup_recipient_phone, '[^0-9]', '', 'g') = regexp_replace(new.seller_phone, '[^0-9]', '', 'g')
        and not exists (select 1 from public.shipments s where s.pickup_request_id = pr.id)
    ) then
      raise exception '인상 전 수거 신청이 있습니다. 기존 신청을 선택하여 상품 등록을 시작해 주세요.';
    end if;
    new.fee_policy_version := '2026-09';
  end if;
  return new;
end;
$$;
revoke all on function public.snapshot_pickup_fee_policy() from public, anon, authenticated;
create trigger pickup_requests_snapshot_fee_policy before insert or update on public.pickup_requests
  for each row execute function public.snapshot_pickup_fee_policy();
create trigger shipments_snapshot_fee_policy before insert or update on public.shipments
  for each row execute function public.snapshot_pickup_fee_policy();

-- 기존 2인자 함수는 유지: 정책 스냅샷 없는 모든 기존 수거는 기존 30/35 또는 40/45%.
create function public.calculate_settlement_fee_percent(p_unit_price integer, p_pickup_date date, p_fee_policy_version text)
returns numeric language sql immutable set search_path = public as $$
  select case when p_fee_policy_version = '2026-09'
    then case when coalesce(p_unit_price, 0) < 10000 then 50 else 45 end::numeric(5,2)
    else public.calculate_settlement_fee_percent(p_unit_price, p_pickup_date) end;
$$;

-- 기존 신청 RPC를 그대로 호출하여 OTP·차단·약관·계좌 자동등록 검증을 보존한다.
create function public.submit_pickup_request_v2(
  p_pickup_recipient_name text, p_pickup_recipient_phone text, p_pickup_postal_code text,
  p_pickup_address_line1 text, p_pickup_address_line2 text, p_pickup_memo text,
  p_settlement_bank_name text, p_settlement_account_number text, p_settlement_account_holder text,
  p_items jsonb, p_settlement_account_id bigint default null, p_pickup_email text default null,
  p_pickup_entrance_password text default null, p_desired_pickup_date date default null,
  p_expected_book_count integer default null, p_box_count integer default null,
  p_policy_agreed boolean default false, p_fee_policy_version text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  if p_fee_policy_version is distinct from '2026-09' then
    raise exception '새로고침 후 수수료 약관을 다시 확인해 주세요.';
  end if;
  perform set_config('subook.pickup_fee_consent', p_fee_policy_version, true);
  v_result := public.submit_pickup_request(
    p_pickup_recipient_name, p_pickup_recipient_phone, p_pickup_postal_code,
    p_pickup_address_line1, p_pickup_address_line2, p_pickup_memo,
    p_settlement_bank_name, p_settlement_account_number, p_settlement_account_holder,
    p_items, p_settlement_account_id, p_pickup_email, p_pickup_entrance_password,
    p_desired_pickup_date, p_expected_book_count, p_box_count, p_policy_agreed);
  perform set_config('subook.pickup_fee_consent', '', true);
  return v_result;
end;
$$;
revoke all on function public.submit_pickup_request_v2(text,text,text,text,text,text,text,text,text,jsonb,bigint,text,text,date,integer,integer,boolean,text) from public, anon;
grant execute on function public.submit_pickup_request_v2(text,text,text,text,text,text,text,text,text,jsonb,bigint,text,text,date,integer,integer,boolean,text) to authenticated;

create function public.admin_create_direct_shipment_v2(
  p_seller_name text, p_seller_phone text, p_pickup_date date,
  p_user_id uuid default null, p_new_fee_policy boolean default false
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not public.is_admin_user() then raise exception 'Admin access required'; end if;
  perform set_config('subook.direct_pickup_new_policy', coalesce(p_new_fee_policy, false)::text, true);
  v_result := public.admin_create_direct_shipment(p_seller_name, p_seller_phone, p_pickup_date, p_user_id);
  perform set_config('subook.direct_pickup_new_policy', '', true);
  return v_result;
end;
$$;
revoke all on function public.admin_create_direct_shipment_v2(text,text,date,uuid,boolean) from public, anon;
grant execute on function public.admin_create_direct_shipment_v2(text,text,date,uuid,boolean) to authenticated;

-- 레거시 셀러 조회도 실제 수거의 정책을 전달한다. 기존 RPC의 반환 계약은 유지.
create function public.lookup_seller_shipment_v2(p_seller_name text, p_seller_phone text)
returns table(id bigint, seller_name text, seller_phone text, pickup_date date, status text, created_at timestamptz, fee_policy_version text)
language sql security definer set search_path = public as $$
  select old.id, old.seller_name, old.seller_phone, old.pickup_date, old.status, old.created_at, s.fee_policy_version
  from public.lookup_seller_shipment(p_seller_name, p_seller_phone) old
  join public.shipments s on s.id = old.id;
$$;
revoke all on function public.lookup_seller_shipment_v2(text,text) from public;
grant execute on function public.lookup_seller_shipment_v2(text,text) to anon, authenticated;

-- 정산 RPC 정의는 아래에 현재 운영 정의를 그대로 복사하고 수수료 계산 인자만 추가한다.

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
     and confirmed_at is not null;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'order_not_confirmed');
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
$function$
;

CREATE OR REPLACE FUNCTION public.admin_commit_manual_settlement(p_items jsonb, p_update_price boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item              jsonb;
  v_book_id           bigint;
  v_sale              integer;
  v_batch             text;
  v_book              record;
  v_fee_percent       numeric(5, 2);
  v_fee               integer;
  v_net               integer;
  v_existing_status   text;
  v_settled_count     integer := 0;
  v_already_settled   integer := 0;
  v_record_created    integer := 0;
  v_record_updated    integer := 0;
  v_price_updated     integer := 0;
  v_skipped_paid      integer := 0;
  v_skipped_discarded integer := 0;
  v_not_found         integer := 0;
  v_skipped_auto_settled integer := 0;
  v_auto_cancelled    integer := 0;
  v_processed_book_ids bigint[] := array[]::bigint[];
  v_uid               uuid := auth.uid();
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_book_id := nullif(v_item->>'book_id', '')::bigint;
    v_sale := greatest(0, coalesce(nullif(v_item->>'sale_amount', '')::integer, 0));
    v_batch := nullif(v_item->>'batch_label', '');

    if v_book_id is null then
      continue;
    end if;

    select b.id, b.status, b.price, b.shipment_id,
           s.seller_name, s.seller_phone, s.pickup_date, s.fee_policy_version
      into v_book
      from public.books b
      left join public.shipments s on s.id = b.shipment_id
      where b.id = v_book_id;

    if not found then
      v_not_found := v_not_found + 1;
      continue;
    end if;

    if v_book.status = 'discarded' then
      v_skipped_discarded := v_skipped_discarded + 1;
      continue;
    end if;

    -- 자동 정산으로 이미 실지급된 책은 수동정산 기록을 만들지 않는다 (이중 지급 방어).
    if exists (
      select 1
      from public.settlements st
      where st.book_id = v_book_id
        and st.status in ('completed', 'recovery_required')
    ) then
      v_skipped_auto_settled := v_skipped_auto_settled + 1;
      continue;
    end if;

    v_processed_book_ids := v_processed_book_ids || v_book_id;

    -- (선택) 판매가 갱신: 엑셀 실판매가로 books.price 정정
    if p_update_price and v_sale > 0 and v_book.price is distinct from v_sale then
      update public.books set price = v_sale where id = v_book_id;
      v_price_updated := v_price_updated + 1;
    end if;

    -- 예상 정산액(참고용): 플랫폼 수수료 공식. 식스샵 실제 정산액과 다를 수 있음.
    v_fee_percent := public.calculate_settlement_fee_percent(v_sale, coalesce(v_book.pickup_date, current_date), v_book.fee_policy_version);
    v_fee := floor(v_sale * (coalesce(v_fee_percent, 0) / 100))::integer;
    v_net := greatest(0, v_sale - v_fee);

    -- 책 상태 플립 (재고 축)
    if v_book.status = 'settled' then
      v_already_settled := v_already_settled + 1;
    elsif v_book.status in ('on_sale', 'reserved') then
      update public.books set status = 'settled' where id = v_book_id;
      v_settled_count := v_settled_count + 1;
    end if;

    -- 정산 레코드 upsert (입금완료 레코드는 금액 보존)
    select status into v_existing_status from public.manual_settlements where book_id = v_book_id;

    if not found then
      insert into public.manual_settlements (
        book_id, shipment_id, seller_name, seller_phone, source, batch_label,
        sale_amount, fee_percent, fee_amount, net_amount, status, created_by
      ) values (
        v_book_id, v_book.shipment_id, v_book.seller_name, v_book.seller_phone, 'sixshop', v_batch,
        v_sale, v_fee_percent, v_fee, v_net, 'unpaid', v_uid
      );
      v_record_created := v_record_created + 1;
    elsif v_existing_status = 'paid' then
      v_skipped_paid := v_skipped_paid + 1;
    else
      update public.manual_settlements set
        shipment_id  = v_book.shipment_id,
        seller_name  = v_book.seller_name,
        seller_phone = v_book.seller_phone,
        batch_label  = coalesce(v_batch, batch_label),
        sale_amount  = v_sale,
        fee_percent  = v_fee_percent,
        fee_amount   = v_fee,
        net_amount   = v_net,
        status       = 'unpaid'
      where book_id = v_book_id;
      v_record_updated := v_record_updated + 1;
    end if;
  end loop;

  -- 수동정산 우선 정책(2026-08-09): 방금 수동정산으로 잡은 책의 대기/승인 자동 정산은
  -- 자동 취소하고, 그 정산이 차감했던 박스비는 shipment로 원복한다(박스비 미회수 상태로 복귀).
  if coalesce(array_length(v_processed_book_ids, 1), 0) > 0 then
    with cancelled as (
      update public.settlements st
      set status = 'cancelled',
          cancelled_at = now(),
          refund_reason = coalesce(st.refund_reason, '수동정산(엑셀) 처리로 자동 취소'),
          updated_at = now()
      where st.book_id = any(v_processed_book_ids)
        and st.status in ('pending', 'approved')
      returning st.book_id, coalesce(st.box_cost_deducted, 0) as box_deduct
    ),
    box_restore as (
      update public.shipments sh
      set box_cost_charged = greatest(0, coalesce(sh.box_cost_charged, 0) - agg.total_deduct)
      from (
        select b.shipment_id, sum(c.box_deduct) as total_deduct
        from cancelled c
        join public.books b on b.id = c.book_id
        where b.shipment_id is not null
          and c.box_deduct > 0
        group by b.shipment_id
      ) agg
      where sh.id = agg.shipment_id
      returning sh.id
    )
    select count(*) into v_auto_cancelled from cancelled;
  end if;

  return jsonb_build_object(
    'settled_count', v_settled_count,
    'already_settled_count', v_already_settled,
    'record_created', v_record_created,
    'record_updated', v_record_updated,
    'price_updated_count', v_price_updated,
    'skipped_paid_count', v_skipped_paid,
    'skipped_discarded_count', v_skipped_discarded,
    'not_found_count', v_not_found,
    'auto_settlement_cancelled', v_auto_cancelled,
    'skipped_auto_settled_count', v_skipped_auto_settled
  );
end;
$function$
;

-- 롤백: 활성화 전에는 프런트만 되돌려도 기존 정산은 영향을 받지 않는다.
-- 활성화 후에는 저장된 정책을 삭제/재계산하지 말고 후속 migration으로 수정한다.
commit;
