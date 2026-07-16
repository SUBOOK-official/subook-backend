-- 셀러별 정산 지급 롤업 + 이체 증빙 (감사 P1)
--
-- 1) settlements.transfer_reference — 완료 처리 시 은행 이체 참조/메모 저장.
--    "입금 안 됐다" 문의 대사 근거. 이체일은 completed_at이 이미 담당.
-- 2) admin_complete_settlements 개정 (1-인자 → 2-인자 default):
--    - p_transfer_reference 저장
--    - ⚠ 레그레션 복구: 20260525 개정에서 결과 jsonb의 seller_name/seller_phone/
--      bank_name/account_last4가 누락됨 → 프론트가 row.seller_phone으로 알림톡
--      대상을 거르므로 "정산 완료 알림톡이 조용히 0건 발송"되던 상태였다.
--      privacy_protection(2026041206) 버전의 enrichment 조인을 복원한다.
--    - 환불 차단 가드·계좌 스냅샷·books settled 전이는 20260525 본문 그대로 유지.
-- 3) admin_list_settlement_payouts — 계좌 단위 지급 롤업 (매월 1일 송금용).
--    예금주/은행/계좌·건수·지급 총액·settlement_ids를 그룹핑해 반환.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 이체 증빙 컬럼
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.settlements
  add column if not exists transfer_reference text null;

comment on column public.settlements.transfer_reference is
  '은행 이체 참조/메모 — admin_complete_settlements가 완료 처리 시 기록. 입금 분쟁 대사 근거.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 완료 처리 RPC 개정 (시그니처 확장 + 알림 필드 복구)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_complete_settlements(bigint[]);

create or replace function public.admin_complete_settlements(
  p_settlement_ids bigint[],
  p_transfer_reference text default null
)
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
    -- 알림톡 발송용 필드 복원 (회원 프로필 우선, 없으면 shipment 스냅샷)
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
    'settlements', coalesce(r.items, '[]'::jsonb)
  )
  into v_result
  from result_rows r;

  return coalesce(v_result, jsonb_build_object('success', true, 'completed_count', 0, 'settlements', '[]'::jsonb));
end;
$$;

grant execute on function public.admin_complete_settlements(bigint[], text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 셀러(계좌) 단위 지급 롤업
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_list_settlement_payouts(
  p_statuses text[] default array['approved']
)
returns jsonb
language plpgsql
security definer
set search_path = public
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
        st.seller_user_id,
        -- 계좌 해석: settlement 스냅샷 우선, 없으면 셀러 기본 계좌 (complete RPC와 동일 규칙)
        coalesce(nullif(btrim(st.bank_name), ''), acc.bank_name, '(계좌 미등록)') as bank_name,
        coalesce(nullif(btrim(st.account_number), ''), acc.account_number, '') as account_number,
        coalesce(nullif(btrim(st.account_holder), ''), acc.account_holder, '(예금주 미등록)') as account_holder,
        max(coalesce(nullif(btrim(mp.name), ''), sh.seller_name, '(이름 없음)')) as seller_name,
        count(*)::integer as settlement_count,
        count(*) filter (where st.status = 'pending')::integer as pending_count,
        count(*) filter (where st.status = 'approved')::integer as approved_count,
        sum(st.net_amount)::bigint as total_net_amount,
        array_agg(st.id order by st.id) as settlement_ids
      from public.settlements st
      left join lateral (
        select msa.bank_name, msa.account_number, msa.account_holder
        from public.member_settlement_accounts msa
        where msa.user_id = st.seller_user_id
        order by msa.is_default desc, msa.created_at desc, msa.id desc
        limit 1
      ) acc on true
      left join public.member_profiles mp on mp.user_id = st.seller_user_id
      left join public.books b on b.id = st.book_id
      left join public.shipments sh on sh.id = b.shipment_id
      where st.status = any(coalesce(p_statuses, array['approved']))
      group by
        st.seller_user_id,
        coalesce(nullif(btrim(st.bank_name), ''), acc.bank_name, '(계좌 미등록)'),
        coalesce(nullif(btrim(st.account_number), ''), acc.account_number, ''),
        coalesce(nullif(btrim(st.account_holder), ''), acc.account_holder, '(예금주 미등록)')
    ) grouped
  ) sub;

  return coalesce(v_result, jsonb_build_object('success', true, 'rows', '[]'::jsonb, 'group_count', 0, 'grand_total', 0));
end;
$$;

grant execute on function public.admin_list_settlement_payouts(text[]) to authenticated;

notify pgrst, 'reload schema';
