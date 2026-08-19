-- 정산 승인 단계 폐지 (pending → completed 직행) + 지급일 도래 슬랙 리마인더 (2026-08-19)
--
-- 배경:
--   1) 기존 정산 흐름은 pending(정산대기) → approved(승인) → completed(정산완료) 3단계.
--      승인은 실무상 아무 것도 하지 않는 중간 클릭이라 폐지 요청 — 대기에서 바로
--      완료(실제 송금 후 기록)로 처리한다.
--   2) 지급일(scheduled_date, 매월 1일)이 도래한 미지급 정산이 있으면 매일 아침
--      슬랙 팀 채널에 수북 알림봇이 @박영제 태그와 함께 지급 목록을 올려준다.
--
-- 설계:
--   * admin_approve_settlements DROP — 승인 단계 진입점 제거 (재도입 금지).
--   * admin_complete_settlements — 'approved' 전용이던 상태 필터를
--     ('pending','approved')로 확장. 기존 approved 64건(2026-09-01 예정)은 레거시로
--     남아 있어 완료 처리가 계속 가능해야 한다. 환불 차단 가드·계좌 스냅샷·
--     books settled 전이·알림톡용 enrichment(20260716035034)는 그대로 유지.
--   * admin_list_settlement_payouts — p_due_only 인자 추가(지급일 도래분만 롤업).
--     기본 상태도 ['pending','approved']로. (시그니처 변경이라 구버전 drop — PostgREST
--     오버로드 모호성 방지)
--   * list_admin_settlements — summary의 due_pending_*를 pending+approved 합산으로
--     확장하고 KST 기준 날짜로 판정 (기존 current_date는 UTC라 1일 오전 9시까지 lag).
--     복호화 실계좌 반환(20260809181841) 로직은 그대로 유지.
--   * notify_slack_settlement_due() — 지급일 도래(pending/approved & scheduled_date
--     <= KST 오늘) 건이 있을 때만 팀 채널로 Block Kit 카드 발송. 0건이면 침묵.
--     ⚠ notify_ops_slack은 쓰지 않는다 — 그 함수는 slack_sys_webhook_url(시스템
--     경보 프라이빗 채널)을 우선하므로, 주문/수거 알림과 같은 팀 채널 시크릿
--     slack_ops_webhook_url을 직접 읽는다.
--   * pg_cron 'subook-settlement-due-reminder' 매일 01:00 UTC(=KST 10:00) 등록 +
--     ops_cron_health_report의 데드맨 스위치 v_expected에 추가(크론 4종 → 5종).
--
-- 비파괴: 함수 재정의 4건 + 신규 함수 1건 + admin_approve_settlements drop(대체 흐름
--   있음) + 크론 등록. 테이블/데이터 변경 없음. status CHECK의 'approved'는 레거시
--   행 호환을 위해 유지한다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 승인 RPC 제거 — 정산대기 → 정산완료 직행 체계에서 승인 진입점 자체를 없앤다
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_approve_settlements(bigint[]);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 완료 처리 RPC — pending도 바로 완료 가능하게 (20260716035034 정의 기반,
--    상태 필터 2곳만 확장. 환불 차단 가드·transfer_reference·enrichment 유지)
-- ─────────────────────────────────────────────────────────────────────────────
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
    and st.status in ('pending', 'approved')
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
    'settlements', coalesce(r.items, '[]'::jsonb)
  )
  into v_result
  from result_rows r;

  return coalesce(v_result, jsonb_build_object('success', true, 'completed_count', 0, 'settlements', '[]'::jsonb));
end;
$$;

grant execute on function public.admin_complete_settlements(bigint[], text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 셀러별 지급 롤업 — p_due_only 추가 (20260809181841 정의 기반, 복호화 유지)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.admin_list_settlement_payouts(text[]);

create or replace function public.admin_list_settlement_payouts(
  p_statuses text[] default array['pending', 'approved'],
  p_due_only boolean default false
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

grant execute on function public.admin_list_settlement_payouts(text[], boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 건별 목록 — summary due_pending_*를 pending+approved 합산·KST 판정으로 확장
--    (20260809181841 정의 기반, 복호화·검색·페이지네이션 유지. 프론트 호환을 위해
--     summary 키 이름은 due_pending_* 그대로 둔다)
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
-- 5) 지급일 도래 슬랙 리마인더 — 팀 채널(주문/수거 알림과 동일 웹훅)로 발송
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.notify_slack_settlement_due()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
  from public.settlements
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
    from public.settlements st
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
$$;

revoke all on function public.notify_slack_settlement_due() from public;
revoke all on function public.notify_slack_settlement_due() from anon;
revoke all on function public.notify_slack_settlement_due() from authenticated;
grant execute on function public.notify_slack_settlement_due() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) 데일리 크론 등록 — 매일 KST 10:00 (01:00 UTC)
-- ─────────────────────────────────────────────────────────────────────────────
do $do$
begin
  if to_regnamespace('cron') is null then
    raise notice 'pg_cron 미설치 — subook-settlement-due-reminder 수동 등록 필요';
    return;
  end if;

  begin
    perform cron.unschedule('subook-settlement-due-reminder');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'subook-settlement-due-reminder',
    '0 1 * * *',
    $job$ select public.notify_slack_settlement_due(); $job$
  );
exception
  when insufficient_privilege or undefined_function or undefined_table then
    null;
end $do$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) 데드맨 스위치 — 기대 크론 목록에 리마인더 추가 (20260816060818 정의 기반,
--    v_expected 5종 + 정상 문구만 변경)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ops_cron_health_report()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lines text[] := array[]::text[];
  v_warn integer := 0;
  v_last timestamptz;
  v_cnt bigint;
  v_name text;
  v_threshold integer;
  v_report text;
  -- 기대 pg_cron 잡과 "이 시간 안에 성공 실행이 없으면 경보" 임계(분).
  -- 주기 대비 넉넉히 잡아 일시 재시도·배포 공백은 무시한다.
  v_expected constant jsonb := jsonb_build_object(
    'subook-expire-unpaid-orders',      120,  -- 15분 주기
    'subook-gsheet-sync-sweep',         60,   -- 5분 주기
    'subook-ai-summary-sweep',          360,  -- 30분 주기
    'subook-privacy-purge',             2880, -- 일 1회 (KST 03:17)
    'subook-settlement-due-reminder',   2880  -- 일 1회 (KST 10:00, 도래 건 없으면 침묵)
  );
begin
  -- 2-1) 기대 잡: 등록 여부 + 최근 성공 실행 여부
  for v_name, v_threshold in
    select key, value::integer from jsonb_each_text(v_expected)
  loop
    if not exists (select 1 from cron.job where jobname = v_name and active) then
      v_warn := v_warn + 1;
      v_lines := v_lines || format('· %s — 크론 미등록/비활성', v_name);
      continue;
    end if;

    select max(d.end_time) into v_last
    from cron.job_run_details d
    join cron.job j on j.jobid = d.jobid
    where j.jobname = v_name
      and d.status = 'succeeded';

    if v_last is null or v_last < now() - make_interval(mins => v_threshold) then
      v_warn := v_warn + 1;
      v_lines := v_lines || format(
        '· %s — 마지막 성공 %s',
        v_name,
        coalesce(to_char(v_last at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), '기록 없음')
      );
    end if;
  end loop;

  -- 2-2) 최근 24시간 실패로 끝난 크론 실행
  select count(*) into v_cnt
  from cron.job_run_details
  where status = 'failed'
    and start_time > now() - interval '24 hours';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· pg_cron 실패 실행 %s건 (24h)', v_cnt);
  end if;

  -- 2-3) 구글시트 아웃박스: 영구 실패 + 1시간 이상 pending 정체
  select count(*) into v_cnt from gsheet_sync_outbox where status = 'failed';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· 구글시트 아웃박스 failed %s건 — admin_gsheet_resend_order로 재기록 필요', v_cnt);
  end if;

  select count(*) into v_cnt
  from gsheet_sync_outbox
  where status = 'pending'
    and created_at < now() - interval '1 hour';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· 구글시트 아웃박스 pending 정체 %s건 (1h+)', v_cnt);
  end if;

  -- 2-4) 알림톡 발송 실패 (최근 24시간)
  select count(*) into v_cnt
  from notification_logs
  where status = 'failed'
    and created_at > now() - interval '24 hours';
  if v_cnt > 0 then
    v_warn := v_warn + 1;
    v_lines := v_lines || format('· 알림톡 실패 %s건 (24h) — 어드민 알림 이력에서 재발송', v_cnt);
  end if;

  -- 2-5) 슬랙 발송 (정상일 때도 한 줄 — 리포트 부재 자체가 장애 신호)
  if v_warn = 0 then
    v_report := ':white_check_mark: 수북 자동화 정상 — 크론 5종·구글시트·알림톡 이상 없음';
  else
    v_report := format(E':rotating_light: 수북 자동화 점검 필요 %s건\n%s', v_warn, array_to_string(v_lines, E'\n'));
  end if;
  perform public.notify_ops_slack(v_report);

  return jsonb_build_object('warnings', v_warn, 'lines', to_jsonb(v_lines));
end;
$$;

revoke all on function public.ops_cron_health_report() from public;
revoke all on function public.ops_cron_health_report() from anon;
revoke all on function public.ops_cron_health_report() from authenticated;
grant execute on function public.ops_cron_health_report() to service_role;

commit;

notify pgrst, 'reload schema';
