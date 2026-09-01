-- 비회원 셀러 자동 정산 편입 (2026-09-01)
--
-- 배경: create_settlements_for_order 가 `seller_user_id is null → continue` 로 정산 생성을
--   건너뛰었다. seller_user_id 는 shipments.user_id 인데, "회원 계정에 연결되지 않은 수거건"을
--   자체매입으로 간주한 것이 오판이었다. 실제로는 식스샵 시절 셀러가 리뉴얼 사이트에
--   가입하지 않아 user_id 가 NULL 인 위탁 셀러였다.
--   → 구매확정 81권 / 매출 458,500원이 자동·수동 어느 정산 목록에도 잡히지 않았고,
--     해당 셀러들의 판매중 재고 975권도 팔릴 때마다 같은 방식으로 샐 예정이었다.
--
-- 정책(사용자 결정 2026-09-01): 비회원 셀러도 자동 정산에 태운다.
--   · 정산 제외 대상은 "수거 건이 아예 없는 자체판매(books.shipment_id IS NULL)" 와
--     "자체매입 버킷(shipments.is_direct_purchase)" 둘뿐이다.
--   · 비회원 셀러 계좌는 회원 계좌(member_settlement_accounts)가 없으므로 shipments 에
--     스냅샷으로 보관한다. 회원 셀러는 기존대로 마이페이지 계좌가 단일 진실.
--
-- ⚠ 재정의 시 유지 필수:
--   - create_settlements_for_order: refunded_at 필터 · 수동정산 제외 · 박스비 차감/이월 ·
--     next_settlement_date(매월 1일) · on conflict(order_id, book_id) ·
--     자체판매/자체매입 skip · 계좌 폴백(회원계좌 → shipments 스냅샷)
--   - admin_complete_settlements: 미해소 환불신청 송금 차단 가드 · books→settled 플립 ·
--     계좌 3종이 모두 있어야 완료 처리
--   - 세 조회/지급 RPC의 계좌 해석 체인에 shipments 스냅샷 폴백
--
-- 되돌리기: create_settlements_for_order 의 skip 조건을
--   `if v_item.seller_user_id is null then continue; end if;` 로 되돌리면 된다
--   (이미 생성된 비회원 셀러 정산 행은 남는다).

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) shipments — 비회원 셀러 정산계좌 스냅샷 + 자체매입 플래그
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.shipments
  add column if not exists settlement_bank_name text,
  add column if not exists settlement_account_number_ciphertext bytea,
  add column if not exists settlement_account_last4 text,
  add column if not exists settlement_account_holder text,
  add column if not exists is_direct_purchase boolean not null default false;

comment on column public.shipments.settlement_bank_name is
  '비회원 셀러 정산계좌 은행. 회원 셀러(user_id 있음)는 member_settlement_accounts 가 단일 진실이라 사용하지 않는다.';
comment on column public.shipments.settlement_account_number_ciphertext is
  '비회원 셀러 정산계좌 번호(암호문). 평문은 저장하지 않는다.';
comment on column public.shipments.is_direct_purchase is
  '자체매입 버킷 여부. true 면 셀러가 없으므로 판매돼도 정산을 생성하지 않는다.';

-- 기존 자체매입 버킷 표시 (2026-05-11 생성된 "수북 자체 매입" shipment)
update public.shipments
   set is_direct_purchase = true
 where btrim(coalesce(seller_name, '')) = '수북 자체 매입'
   and is_direct_purchase is distinct from true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) admin_upsert_shipment_settlement_account — 비회원 셀러 계좌 등록/수정
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_upsert_shipment_settlement_account(
  p_shipment_id bigint,
  p_bank_name text,
  p_account_number text,
  p_account_holder text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_shipment record;
  v_normalized text;
  v_last4 text;
  v_cipher bytea;
  v_synced integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select id, user_id, seller_name
    into v_shipment
    from public.shipments
   where id = p_shipment_id;

  if not found then
    raise exception '수거 건을 찾을 수 없습니다. (id=%)', p_shipment_id;
  end if;

  -- 회원 셀러는 마이페이지 정산계좌가 단일 진실 — 여기서 덮어쓰면 두 곳이 갈라진다.
  if v_shipment.user_id is not null then
    raise exception '회원 셀러 수거 건입니다. 회원 정산계좌(마이페이지)를 사용해 주세요.';
  end if;

  if nullif(btrim(coalesce(p_bank_name, '')), '') is null then
    raise exception '은행명을 입력해 주세요.';
  end if;
  if nullif(btrim(coalesce(p_account_holder, '')), '') is null then
    raise exception '예금주를 입력해 주세요.';
  end if;

  v_normalized := public.normalize_account_number(p_account_number);
  if v_normalized is null then
    raise exception '계좌번호를 입력해 주세요.';
  end if;

  v_last4 := public.get_account_last4(v_normalized);
  v_cipher := public.encrypt_account_number(v_normalized);

  update public.shipments
     set settlement_bank_name = btrim(p_bank_name),
         settlement_account_number_ciphertext = v_cipher,
         settlement_account_last4 = v_last4,
         settlement_account_holder = btrim(p_account_holder)
   where id = p_shipment_id;

  -- 이미 만들어진 미지급 정산의 계좌 스냅샷도 함께 갱신한다.
  -- (지급 롤업이 계좌 기준으로 그룹핑하므로 스냅샷이 비어 있으면 '(계좌 미등록)' 그룹으로 샌다)
  with synced as (
    update public.settlements st
       set bank_name = btrim(p_bank_name),
           account_number = public.mask_account_number(v_last4),
           account_number_ciphertext = v_cipher,
           account_number_last4 = v_last4,
           account_holder = btrim(p_account_holder)
      from public.books b
     where b.id = st.book_id
       and b.shipment_id = p_shipment_id
       and st.seller_user_id is null
       and st.status in ('pending', 'approved')
    returning st.id
  )
  select count(*)::integer into v_synced from synced;

  return jsonb_build_object(
    'success', true,
    'shipment_id', p_shipment_id,
    'seller_name', v_shipment.seller_name,
    'account_last4', v_last4,
    'synced_settlement_count', v_synced
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) create_settlements_for_order — 비회원 셀러 포함, 자체판매/자체매입만 제외
--    (20260809095729 최신 정의 기반)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_settlements_for_order(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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

    v_fee_percent := public.calculate_settlement_fee_percent(v_unit_price, v_item.pickup_date);
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
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 수거건이 뒤늦게 회원과 연결되면 미지급 정산의 셀러도 승계
--    (비회원으로 만들어진 정산이 셀러 마이페이지에서 영영 안 보이는 것 방지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sync_settlement_seller_on_shipment_link()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.settlements st
     set seller_user_id = new.user_id
    from public.books b
   where b.id = st.book_id
     and b.shipment_id = new.id
     and st.seller_user_id is null
     and st.status in ('pending', 'approved');

  return new;
end;
$$;

drop trigger if exists trg_shipments_sync_settlement_seller on public.shipments;
create trigger trg_shipments_sync_settlement_seller
after update of user_id on public.shipments
for each row
when (new.user_id is not null and old.user_id is distinct from new.user_id)
execute function public.sync_settlement_seller_on_shipment_link();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) admin_complete_settlements — 계좌 해석에 shipments 스냅샷 폴백 추가
--    + 프론트가 읽는 updated_count / skipped_missing_account_count 반환
--    (기존 정의 기반. ⚠ 미해소 환불신청 송금 차단 가드 유지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_complete_settlements(
  p_settlement_ids bigint[],
  p_transfer_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_result jsonb;
  v_blocked_count integer;
  v_blocked_orders text;
  v_target_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- ⚠ 미해소 환불 신청(refund_requested_at 있고 아직 환불 처리/반려 안 됨) 주문에
  --    묶인 settlement는 송금 차단. 해소(부분환불 처리·반려) 후에는 잔여 품목 정산 송금 가능.
  select count(*)::integer, string_agg(distinct o.order_number, ', ')
    into v_blocked_count, v_blocked_orders
  from public.settlements st
  inner join public.orders o on o.id = st.order_id
  where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
    and st.status in ('pending', 'approved')
    and o.refund_requested_at is not null
    and o.refund_request_resolved_at is null
    and o.status <> 'refunded';

  if coalesce(v_blocked_count, 0) > 0 then
    raise exception '환불 신청이 접수된 주문이 포함되어 송금을 진행할 수 없습니다. (주문번호: %) 환불 처리 또는 신청 반려를 먼저 완료해주세요.',
      v_blocked_orders;
  end if;

  select count(*)::integer
    into v_target_count
  from public.settlements st
  where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
    and st.status in ('pending', 'approved');

  with account_snapshot as (
    select
      st.id,
      -- 계좌 해석: settlement 스냅샷 → 회원 기본계좌 → 비회원 셀러 shipments 스냅샷
      coalesce(
        nullif(btrim(st.bank_name), ''),
        account.bank_name,
        nullif(btrim(sh.settlement_bank_name), '')
      ) as next_bank_name,
      coalesce(
        nullif(btrim(st.account_number), ''),
        account.account_number,
        public.mask_account_number(sh.settlement_account_last4)
      ) as next_account_number,
      coalesce(
        nullif(btrim(st.account_holder), ''),
        account.account_holder,
        nullif(btrim(sh.settlement_account_holder), '')
      ) as next_account_holder
    from public.settlements st
    left join public.books b on b.id = st.book_id
    left join public.shipments sh on sh.id = b.shipment_id
    left join lateral (
      select
        msa.bank_name,
        msa.account_number,
        msa.account_holder
      from public.member_settlement_accounts msa
      where msa.user_id = st.seller_user_id
      order by msa.is_default desc, msa.created_at desc, msa.id desc
      limit 1
    ) account on true
    where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
      -- 승인 단계 폐지: 정산대기(pending)도 송금 후 바로 완료 처리 (approved는 레거시 행)
      and st.status in ('pending', 'approved')
  ),
  updated as (
    update public.settlements st
    set
      status = 'completed',
      completed_at = now(),
      transfer_reference = coalesce(nullif(btrim(p_transfer_reference), ''), st.transfer_reference),
      bank_name = account_snapshot.next_bank_name,
      account_number = account_snapshot.next_account_number,
      account_holder = account_snapshot.next_account_holder
    from account_snapshot
    where st.id = account_snapshot.id
      and nullif(btrim(coalesce(account_snapshot.next_bank_name, '')), '') is not null
      and nullif(btrim(coalesce(account_snapshot.next_account_number, '')), '') is not null
      and nullif(btrim(coalesce(account_snapshot.next_account_holder, '')), '') is not null
    returning st.*
  ),
  settled_books as (
    update public.books b
    set status = 'settled'
    where b.id in (select book_id from updated)
      and b.status <> 'settled'
    returning b.id
  ),
  enriched as (
    -- 알림톡 발송용 필드 (회원 프로필 우선, 없으면 shipment 스냅샷)
    select
      u.*,
      o.order_number,
      coalesce(oi.title, b.title) as book_title,
      coalesce(nullif(btrim(mp.name), ''), sh.seller_name) as resolved_seller_name,
      coalesce(nullif(btrim(mp.phone), ''), sh.seller_phone) as resolved_seller_phone
    from updated u
    left join public.orders o on o.id = u.order_id
    left join public.order_items oi on oi.id = u.order_item_id
    left join public.books b on b.id = u.book_id
    left join public.shipments sh on sh.id = b.shipment_id
    left join public.member_profiles mp on mp.user_id = u.seller_user_id
  ),
  result_rows as (
    select
      jsonb_agg(
        jsonb_build_object(
          'id', e.id,
          'order_id', e.order_id,
          'order_number', e.order_number,
          'book_title', e.book_title,
          'seller_user_id', e.seller_user_id,
          'seller_name', e.resolved_seller_name,
          'seller_phone', e.resolved_seller_phone,
          'net_amount', e.net_amount,
          'bank_name', e.bank_name,
          'account_last4', public.get_account_last4(e.account_number),
          'transfer_reference', e.transfer_reference,
          'status', e.status,
          'completed_at', e.completed_at
        )
        order by e.completed_at desc nulls last, e.id desc
      ) as items,
      count(*)::integer as count
    from enriched e
  )
  select jsonb_build_object(
    'success', true,
    'completed_count', coalesce(r.count, 0),
    -- 프론트(AdminSettlementsPage)가 읽는 키. 계좌 미등록으로 건너뛴 건수를 함께 알린다.
    'updated_count', coalesce(r.count, 0),
    'skipped_missing_account_count', greatest(0, coalesce(v_target_count, 0) - coalesce(r.count, 0)),
    'settlements', coalesce(r.items, '[]'::jsonb)
  )
  into v_result
  from result_rows r;

  return coalesce(
    v_result,
    jsonb_build_object(
      'success', true,
      'completed_count', 0,
      'updated_count', 0,
      'skipped_missing_account_count', coalesce(v_target_count, 0),
      'settlements', '[]'::jsonb
    )
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) list_admin_settlements — 계좌 해석에 shipments 스냅샷 폴백 추가
--    (기존 정의 기반. 나머지 로직 동일)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_admin_settlements(
  p_statuses text[] default null::text[],
  p_search text default null::text,
  p_from_date date default null::date,
  p_to_date date default null::date,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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
    join public.orders o
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
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) admin_list_settlement_payouts — 계좌 해석에 shipments 스냅샷 폴백 추가
--    (기존 정의 기반. 그룹핑 규칙 동일)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_list_settlement_payouts(
  p_statuses text[] default array['pending'::text, 'approved'::text],
  p_due_only boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select jsonb_build_object(
    'success', true,
    'rows', coalesce(jsonb_agg(row_data order by (row_data->>'total_net_amount')::bigint desc), '[]'::jsonb),
    'group_count', count(*),
    'grand_total', coalesce(sum((row_data->>'total_net_amount')::bigint), 0)
  )
  into v_result
  from (
    select jsonb_build_object(
      'seller_user_id', grouped.seller_user_id,
      'seller_name', grouped.seller_name,
      'bank_name', grouped.bank_name,
      'account_number', grouped.account_number,
      'account_holder', grouped.account_holder,
      'settlement_count', grouped.settlement_count,
      'pending_count', grouped.pending_count,
      'approved_count', grouped.approved_count,
      'total_net_amount', grouped.total_net_amount,
      'settlement_ids', grouped.settlement_ids
    ) as row_data
    from (
      select
        resolved.seller_user_id,
        resolved.bank_name,
        resolved.account_number,
        resolved.account_holder,
        max(resolved.seller_name) as seller_name,
        count(*)::integer as settlement_count,
        count(*) filter (where resolved.status = 'pending')::integer as pending_count,
        count(*) filter (where resolved.status = 'approved')::integer as approved_count,
        sum(resolved.net_amount)::bigint as total_net_amount,
        array_agg(resolved.id order by resolved.id) as settlement_ids
      from (
        select
          st.id,
          st.status,
          st.net_amount,
          st.seller_user_id,
          -- 계좌 해석: settlement 스냅샷 → 셀러 기본 계좌 → 비회원 셀러 shipments 스냅샷
          -- (complete RPC와 동일 규칙).
          -- 어드민 마스킹 해제(2026-07-24): 송금용 실번호를 복호화해 노출, 암호문 없으면 마스킹 폴백.
          coalesce(
            nullif(btrim(st.bank_name), ''),
            acc.bank_name,
            nullif(btrim(sh.settlement_bank_name), ''),
            '(계좌 미등록)'
          ) as bank_name,
          coalesce(
            public.decrypt_account_number(
              coalesce(
                st.account_number_ciphertext,
                acc.account_number_ciphertext,
                sh.settlement_account_number_ciphertext
              )
            ),
            nullif(btrim(st.account_number), ''),
            acc.account_number,
            public.mask_account_number(sh.settlement_account_last4),
            ''
          ) as account_number,
          coalesce(
            nullif(btrim(st.account_holder), ''),
            acc.account_holder,
            nullif(btrim(sh.settlement_account_holder), ''),
            '(예금주 미등록)'
          ) as account_holder,
          coalesce(nullif(btrim(mp.name), ''), sh.seller_name, '(이름 없음)') as seller_name
        from public.settlements st
        left join lateral (
          select msa.bank_name, msa.account_number, msa.account_number_ciphertext, msa.account_holder
          from public.member_settlement_accounts msa
          where msa.user_id = st.seller_user_id
          order by msa.is_default desc, msa.created_at desc, msa.id desc
          limit 1
        ) acc on true
        left join public.member_profiles mp on mp.user_id = st.seller_user_id
        left join public.books b on b.id = st.book_id
        left join public.shipments sh on sh.id = b.shipment_id
        where st.status = any(coalesce(p_statuses, array['pending', 'approved']))
          -- 지급일 도래분만 (매월 1일 사이클) — KST 기준
          and (
            not coalesce(p_due_only, false)
            or st.scheduled_date <= (now() at time zone 'Asia/Seoul')::date
          )
      ) resolved
      group by
        resolved.seller_user_id,
        resolved.bank_name,
        resolved.account_number,
        resolved.account_holder
    ) grouped
  ) sub;

  return coalesce(v_result, jsonb_build_object('success', true, 'rows', '[]'::jsonb, 'group_count', 0, 'grand_total', 0));
end;
$$;

commit;
