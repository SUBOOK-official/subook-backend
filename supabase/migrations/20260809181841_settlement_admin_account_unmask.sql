-- 어드민 정산 화면 실계좌 노출 (2026-07-24 어드민 마스킹 전면 해제 정책의 정산 잔여분)
--
-- 문제: settlements.account_number / member_settlement_accounts.account_number는
--   privacy 마이그레이션 이후 마스킹 값(****1234)만 담고 실번호는 ciphertext에 있음.
--   admin 목록·셀러별 지급 롤업이 마스킹 값을 그대로 반환해 운영자가 송금할 계좌를
--   볼 수 없었고, "평문 계좌 엑셀" 다운로드(plain=true, row.account_number 사용)도
--   사실상 마스킹 값을 내보내고 있었다.
--
-- 수정 (admin 전용 RPC 2종 — is_admin_user() 가드 하에서만 복호화):
--   1) list_admin_settlements: account_number = 복호화 실번호 우선, 폴백 마스킹.
--      pending 행은 스냅샷이 없으므로 셀러 현재 기본계좌로 폴백(승인 시 박힐 값 미리보기,
--      admin_list_settlement_payouts와 동일 해석 규칙). bank/holder/last4도 동일 폴백.
--   2) admin_list_settlement_payouts: 그룹 키의 account_number를 복호화 실번호로 해석.
--
-- ⚠ 유지 필수: 셀러 화면(get_my_settlements)은 계속 마스킹 — 이 마이그레이션은
--   admin RPC만 건드린다. 재정의 시 복호화(coalesce(스냅샷, 기본계좌 ciphertext)) 유지.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) list_admin_settlements — 실계좌 반환 + pending 기본계좌 폴백
--    (2026041206 최신 정의 기반)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_admin_settlements(
  p_statuses text[] default null,
  p_search text default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 100,
  p_offset integer default 0
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
      -- 계좌 해석: settlement 스냅샷 우선, 없으면 셀러 현재 기본계좌 (지급 롤업과 동일 규칙)
      coalesce(nullif(btrim(st.bank_name), ''), acc.bank_name) as resolved_bank_name,
      coalesce(nullif(btrim(st.account_holder), ''), acc.account_holder) as resolved_account_holder,
      coalesce(st.account_number_ciphertext, acc.account_number_ciphertext) as resolved_ciphertext,
      coalesce(
        st.account_number_last4,
        public.get_account_last4(st.account_number),
        acc.account_number_last4,
        public.get_account_last4(acc.account_number)
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
      'due_pending_count', (select count(*) from filtered where status = 'pending' and scheduled_date <= current_date),
      'due_pending_amount', coalesce((select sum(net_amount) from filtered where status = 'pending' and scheduled_date <= current_date), 0)
    )
  )
  into v_result;

  return v_result;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) admin_list_settlement_payouts — 그룹 키를 복호화 실번호로 해석
--    (20260716035034 최신 정의 기반 — 롤업 구조·필드 유지)
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
          -- 계좌 해석: settlement 스냅샷 우선, 없으면 셀러 기본 계좌 (complete RPC와 동일 규칙).
          -- 어드민 마스킹 해제(2026-07-24): 송금용 실번호를 복호화해 노출, 암호문 없으면 마스킹 폴백.
          coalesce(nullif(btrim(st.bank_name), ''), acc.bank_name, '(계좌 미등록)') as bank_name,
          coalesce(
            public.decrypt_account_number(coalesce(st.account_number_ciphertext, acc.account_number_ciphertext)),
            nullif(btrim(st.account_number), ''),
            acc.account_number,
            ''
          ) as account_number,
          coalesce(nullif(btrim(st.account_holder), ''), acc.account_holder, '(예금주 미등록)') as account_holder,
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
        where st.status = any(coalesce(p_statuses, array['approved']))
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

notify pgrst, 'reload schema';
