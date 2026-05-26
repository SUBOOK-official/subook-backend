-- 정산 회수(settlement_recovery_required) 시나리오를 발생 빈도 자체에서 차단.
--
-- 배경: 구매자가 환불 신청을 너무 늦게 하면 셀러에게 이미 송금된 정산을
-- 회수해야 함 — 현실적으로 셀러 협조 없이는 회수 불가능. 그래서 두 가지 가드:
--
-- A. request_member_refund: confirmed 상태에선 환불 신청 차단.
--    - delivered → 7일 자동 confirmed → +3 영업일 송금 흐름에서 delivered+7일이
--      청약철회 기간(전자상거래법) 한계. confirmed 도달 시점이면 청약철회 기간 넘김.
--    - 따라서 confirmed 후 환불은 admin 수동(고객센터 협의)으로만 가능.
--
-- B. admin_complete_settlements: 송금 처리 시 동일 주문에 환불 신청이
--    접수돼 있으면 차단. admin이 환불 처리를 먼저 끝낸 후에 송금하도록 강제.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- A) request_member_refund: confirmed 차단
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.request_member_refund(
  p_order_id bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order public.orders%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_now timestamptz := now();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if v_reason is null or length(v_reason) < 4 then
    raise exception '환불 사유는 4자 이상 입력해주세요.';
  end if;

  select * into v_order
    from public.orders
   where id = p_order_id and user_id = v_user_id
   for update;

  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status not in ('delivered', 'confirmed') then
    raise exception '배송완료 또는 구매확정 상태에서만 환불을 신청할 수 있습니다. (현재: %)', v_order.status;
  end if;

  if v_order.refund_requested_at is not null then
    raise exception '이미 환불 신청이 접수되었습니다. (접수일: %)', to_char(v_order.refund_requested_at, 'YYYY-MM-DD HH24:MI');
  end if;

  -- delivered: 배송완료 후 7일 이내만 (전자상거래법 청약철회권)
  if v_order.status = 'delivered' then
    if coalesce(v_order.updated_at, v_order.created_at) < (v_now - interval '7 days') then
      raise exception '배송완료 후 7일이 지나 환불 신청이 어렵습니다. 고객센터에 문의해주세요.';
    end if;
  end if;

  -- ⚠ confirmed: 환불 신청 차단. 셀러 정산 송금이 이미 진행됐을 가능성이
  --    높아 회수 시나리오 발생. confirmed 후 환불은 고객센터 협의 후 admin이
  --    admin_refund_order로 직접 처리.
  if v_order.status = 'confirmed' then
    raise exception '구매확정된 주문은 셀프 환불 신청이 어렵습니다. 카카오톡 채널 또는 고객센터(subook2025@gmail.com)로 문의해주세요.';
  end if;

  update public.orders
     set refund_requested_at = v_now,
         refund_request_reason = v_reason,
         updated_at = v_now
   where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'requested_at', v_now,
    'reason', v_reason
  );
end;
$$;

grant execute on function public.request_member_refund(bigint, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- B) admin_complete_settlements: 환불 신청 접수된 주문 송금 차단
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_complete_settlements(p_settlement_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_blocked_count integer;
  v_blocked_orders text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- ⚠ 환불 신청이 접수된 주문(refund_requested_at IS NOT NULL, refunded 아님)에
  --    묶인 settlement는 송금 차단. admin이 환불 처리를 먼저 끝내야 함.
  select count(*)::integer, string_agg(distinct o.order_number, ', ')
    into v_blocked_count, v_blocked_orders
  from public.settlements st
  inner join public.orders o on o.id = st.order_id
  where st.id = any(coalesce(p_settlement_ids, '{}'::bigint[]))
    and st.status = 'approved'
    and o.refund_requested_at is not null
    and o.status <> 'refunded';

  if coalesce(v_blocked_count, 0) > 0 then
    raise exception '환불 신청이 접수된 주문이 포함되어 송금을 진행할 수 없습니다. (주문번호: %) 환불 처리를 먼저 완료해주세요.',
      v_blocked_orders;
  end if;

  with account_snapshot as (
    select
      st.id,
      coalesce(nullif(btrim(st.bank_name), ''), account.bank_name) as next_bank_name,
      coalesce(nullif(btrim(st.account_number), ''), account.account_number) as next_account_number,
      coalesce(nullif(btrim(st.account_holder), ''), account.account_holder) as next_account_holder
    from public.settlements st
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
      and st.status = 'approved'
  ),
  updated as (
    update public.settlements st
    set
      status = 'completed',
      completed_at = now(),
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
  result_rows as (
    select
      jsonb_agg(
        jsonb_build_object(
          'id', u.id,
          'order_id', u.order_id,
          'seller_user_id', u.seller_user_id,
          'net_amount', u.net_amount,
          'status', u.status,
          'completed_at', u.completed_at
        )
        order by u.completed_at desc nulls last, u.id desc
      ) as items,
      count(*)::integer as count
    from updated u
  )
  select jsonb_build_object(
    'success', true,
    'completed_count', coalesce(r.count, 0),
    'settlements', coalesce(r.items, '[]'::jsonb)
  )
  into v_result
  from result_rows r;

  return coalesce(v_result, jsonb_build_object('success', true, 'completed_count', 0, 'settlements', '[]'::jsonb));
end;
$$;

grant execute on function public.admin_complete_settlements(bigint[]) to authenticated;

commit;
