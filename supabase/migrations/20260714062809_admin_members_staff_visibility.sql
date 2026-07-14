-- 회원 관리에 운영진(dual-role) 계정 표시 (2026-07-14)
--
-- 배경: list_admin_members / get_admin_member_detail 은 admin_users 등록 이메일을
--   회원 목록에서 제외해 왔다 (관리자↔회원이 상호배타이던 2026-04 설계).
--   20260709191541(dual-role) 개편으로 관리자도 member_profiles 에 등록되는데,
--   현재 가입 계정 전원이 운영진이라 회원 관리 화면이 항상 0건으로 보였다.
--
-- 조치:
--   1) list_admin_members: 운영진 제외 필터 제거 + is_staff 반환 (운영진 배지용).
--      상단 요약 카드(전체 회원·구매액·판매액)도 운영진 활동을 포함하게 된다.
--   2) get_admin_member_detail: 동일하게 제거 + is_staff 반환 (상세 모달 진입 가능).
--   3) admin_block_member: 운영진 차단 금지 가드 — 차단은 auth 레벨 밴이라
--      admin-web 접근까지 잠기므로, 목록 노출로 접근 가능해진 차단 버튼 사고 방지.
--
-- 반환 jsonb 는 키 추가만 있고 기존 키·구조 불변 → 프론트 하위호환.

begin;

create or replace function public.list_admin_members(
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_status text default null
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

  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits,
      nullif(btrim(coalesce(p_status, '')), '') as status_filter
  ),
  members as (
    select
      mp.user_id,
      mp.email,
      mp.name,
      mp.nickname,
      coalesce(nullif(btrim(mp.nickname), ''), nullif(btrim(mp.name), ''), mp.email) as display_name,
      mp.phone,
      coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
      mp.email_verified_at,
      coalesce(au.created_at, mp.created_at) as joined_at,
      mp.created_at,
      mp.updated_at,
      coalesce(mp.is_blocked, false) as is_blocked,
      mp.blocked_at,
      mp.block_reason,
      mp.withdrawal_requested_at,
      mp.personal_data_erased_at,
      -- 운영진 여부: admin_users 등록 이메일 (dual-role — 회원이자 관리자)
      exists (
        select 1
        from public.admin_users admin_user
        where lower(admin_user.email) = lower(mp.email)
      ) as is_staff,
      -- 단일 상태값으로 정규화 (우선순위: 탈퇴완료 > 탈퇴대기 > 차단 > 정상)
      case
        when mp.personal_data_erased_at is not null then 'withdrawn'
        when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
        when coalesce(mp.is_blocked, false) then 'blocked'
        else 'active'
      end as account_status
    from public.member_profiles mp
    left join auth.users au
      on au.id = mp.user_id
    cross join params
    where (
        params.search_term = ''
        or mp.name ilike '%' || params.search_term || '%'
        or coalesce(mp.nickname, '') ilike '%' || params.search_term || '%'
        or mp.email ilike '%' || params.search_term || '%'
        or coalesce(mp.phone, '') ilike '%' || params.search_term || '%'
        or (
          params.search_digits <> ''
          and regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') like '%' || params.search_digits || '%'
        )
      )
    -- ⚠ 상태 필터는 여기서 적용하지 않는다. (칩 카운트가 전체 분포를 보여줘야 하므로)
  ),
  enriched as (
    select
      m.*,
      coalesce(pickup_stats.pickup_request_count, 0) as pickup_request_count,
      coalesce(pickup_stats.pickup_item_count, 0) as pickup_request_item_count,
      coalesce(shipment_stats.legacy_shipment_count, 0) as legacy_shipment_count,
      coalesce(shipment_stats.legacy_book_count, 0) as legacy_book_count,
      coalesce(order_stats.order_count, 0) as order_count,
      coalesce(order_stats.purchase_amount, 0) as purchase_amount,
      coalesce(settlement_stats.settlement_count, 0) as settlement_count,
      coalesce(settlement_stats.sale_amount, 0) + coalesce(legacy_sale_stats.sale_amount, 0) as sale_amount,
      coalesce(settlement_stats.net_amount, 0) as net_settlement_amount,
      greatest(
        coalesce(pickup_stats.latest_pickup_at, 'epoch'::timestamptz),
        coalesce(shipment_stats.latest_shipment_at, 'epoch'::timestamptz),
        coalesce(order_stats.latest_order_at, 'epoch'::timestamptz),
        coalesce(settlement_stats.latest_settlement_at, 'epoch'::timestamptz)
      ) as latest_activity_at
    from members m
    left join lateral (
      select
        count(*)::integer as pickup_request_count,
        coalesce(sum(pr.item_count), 0)::integer as pickup_item_count,
        max(pr.created_at) as latest_pickup_at
      from public.pickup_requests pr
      where pr.user_id = m.user_id
    ) pickup_stats on true
    left join lateral (
      select
        count(distinct s.id)::integer as legacy_shipment_count,
        count(b.id)::integer as legacy_book_count,
        max(s.created_at) as latest_shipment_at
      from public.shipments s
      left join public.books b
        on b.shipment_id = s.id
      where s.user_id = m.user_id
    ) shipment_stats on true
    left join lateral (
      select
        count(*)::integer as order_count,
        coalesce(sum(o.total_amount) filter (where o.status not in ('cancelled', 'refunded')), 0)::integer as purchase_amount,
        max(o.created_at) as latest_order_at
      from public.orders o
      where o.user_id = m.user_id
    ) order_stats on true
    left join lateral (
      select
        count(*)::integer as settlement_count,
        coalesce(sum(st.sale_amount), 0)::integer as sale_amount,
        coalesce(sum(st.net_amount), 0)::integer as net_amount,
        max(coalesce(st.completed_at, st.approved_at, st.created_at)) as latest_settlement_at
      from public.settlements st
      where st.seller_user_id = m.user_id
    ) settlement_stats on true
    left join lateral (
      select
        coalesce(sum(b.price), 0)::integer as sale_amount
      from public.shipments s
      join public.books b
        on b.shipment_id = s.id
      where s.user_id = m.user_id
        and b.status = 'settled'
        and not exists (
          select 1
          from public.settlements st
          where st.book_id = b.id
        )
    ) legacy_sale_stats on true
  ),
  -- 상태 필터는 여기서만 적용 → 실제 목록·total_count 기준.
  visible as (
    select e.*
    from enriched e
    cross join params
    where params.status_filter is null
      or params.status_filter = 'all'
      or e.account_status = params.status_filter
  ),
  page_rows as (
    select *
    from visible
    order by joined_at desc, user_id
    offset greatest(0, coalesce(p_offset, 0))
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  )
  select jsonb_build_object(
    'rows',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'user_id', row_data.user_id,
              'email', row_data.email,
              'name', row_data.name,
              'nickname', row_data.nickname,
              'display_name', row_data.display_name,
              'phone', row_data.phone,
              'marketing_opt_in', row_data.marketing_opt_in,
              'email_verified_at', row_data.email_verified_at,
              'joined_at', row_data.joined_at,
              'created_at', row_data.created_at,
              'updated_at', row_data.updated_at,
              'is_blocked', row_data.is_blocked,
              'blocked_at', row_data.blocked_at,
              'block_reason', row_data.block_reason,
              'withdrawal_requested_at', row_data.withdrawal_requested_at,
              'personal_data_erased_at', row_data.personal_data_erased_at,
              'account_status', row_data.account_status,
              'is_staff', row_data.is_staff,
              'pickup_count', row_data.pickup_request_count + row_data.legacy_shipment_count,
              'pickup_item_count', row_data.pickup_request_item_count + row_data.legacy_book_count,
              'order_count', row_data.order_count,
              'purchase_amount', row_data.purchase_amount,
              'settlement_count', row_data.settlement_count,
              'sale_amount', row_data.sale_amount,
              'net_settlement_amount', row_data.net_settlement_amount,
              'latest_activity_at', nullif(row_data.latest_activity_at, 'epoch'::timestamptz)
            )
            order by row_data.joined_at desc, row_data.user_id
          )
          from page_rows row_data
        ),
        '[]'::jsonb
      ),
    -- 목록 페이지네이션 기준: 상태 필터 적용된 visible
    'total_count', (select count(*) from visible),
    'summary',
      jsonb_build_object(
        -- 상태별 카운트·전체 분포: 상태 필터 미적용 enriched 기준(항상 안정)
        'member_count', (select count(*) from enriched),
        'new_member_count_30d', (
          select count(*)
          from enriched
          where joined_at >= now() - interval '30 days'
        ),
        'purchase_amount', coalesce((select sum(purchase_amount) from enriched), 0),
        'sale_amount', coalesce((select sum(sale_amount) from enriched), 0),
        'pickup_count', coalesce((select sum(pickup_request_count + legacy_shipment_count) from enriched), 0),
        'order_count', coalesce((select sum(order_count) from enriched), 0),
        'active_count', (select count(*) from enriched where account_status = 'active'),
        'blocked_count', (select count(*) from enriched where account_status = 'blocked'),
        'withdrawal_pending_count', (select count(*) from enriched where account_status = 'withdrawal_pending'),
        'withdrawn_count', (select count(*) from enriched where account_status = 'withdrawn')
      )
  )
  into v_result;

  return v_result;
end;
$$;

create or replace function public.get_admin_member_detail(
  p_user_id uuid
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

  if p_user_id is null then
    raise exception 'Member id is required';
  end if;

  with member_base as (
    select
      mp.user_id,
      mp.email,
      mp.name,
      mp.nickname,
      coalesce(nullif(btrim(mp.nickname), ''), nullif(btrim(mp.name), ''), mp.email) as display_name,
      mp.phone,
      coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
      mp.email_verified_at,
      coalesce(au.created_at, mp.created_at) as joined_at,
      mp.created_at,
      mp.updated_at,
      au.last_sign_in_at,
      -- 운영진 여부: admin_users 등록 이메일 (dual-role — 회원이자 관리자)
      exists (
        select 1
        from public.admin_users admin_user
        where lower(admin_user.email) = lower(mp.email)
      ) as is_staff
    from public.member_profiles mp
    left join auth.users au
      on au.id = mp.user_id
    where mp.user_id = p_user_id
  ),
  summary as (
    select
      mb.user_id,
      coalesce(pickup_stats.pickup_request_count, 0) + coalesce(shipment_stats.legacy_shipment_count, 0) as pickup_count,
      coalesce(pickup_stats.pickup_item_count, 0) + coalesce(shipment_stats.legacy_book_count, 0) as pickup_item_count,
      coalesce(order_stats.order_count, 0) as order_count,
      coalesce(order_stats.purchase_amount, 0) as purchase_amount,
      coalesce(settlement_stats.settlement_count, 0) as settlement_count,
      coalesce(settlement_stats.sale_amount, 0) + coalesce(legacy_sale_stats.sale_amount, 0) as sale_amount,
      coalesce(settlement_stats.net_amount, 0) as net_settlement_amount,
      coalesce(address_stats.shipping_address_count, 0) as shipping_address_count,
      coalesce(account_stats.settlement_account_count, 0) as settlement_account_count
    from member_base mb
    left join lateral (
      select
        count(*)::integer as pickup_request_count,
        coalesce(sum(pr.item_count), 0)::integer as pickup_item_count
      from public.pickup_requests pr
      where pr.user_id = mb.user_id
    ) pickup_stats on true
    left join lateral (
      select
        count(distinct s.id)::integer as legacy_shipment_count,
        count(b.id)::integer as legacy_book_count
      from public.shipments s
      left join public.books b
        on b.shipment_id = s.id
      where s.user_id = mb.user_id
    ) shipment_stats on true
    left join lateral (
      select
        count(*)::integer as order_count,
        coalesce(sum(o.total_amount) filter (where o.status not in ('cancelled', 'refunded')), 0)::integer as purchase_amount
      from public.orders o
      where o.user_id = mb.user_id
    ) order_stats on true
    left join lateral (
      select
        count(*)::integer as settlement_count,
        coalesce(sum(st.sale_amount), 0)::integer as sale_amount,
        coalesce(sum(st.net_amount), 0)::integer as net_amount
      from public.settlements st
      where st.seller_user_id = mb.user_id
    ) settlement_stats on true
    left join lateral (
      select
        coalesce(sum(b.price), 0)::integer as sale_amount
      from public.shipments s
      join public.books b
        on b.shipment_id = s.id
      where s.user_id = mb.user_id
        and b.status = 'settled'
        and not exists (
          select 1
          from public.settlements st
          where st.book_id = b.id
        )
    ) legacy_sale_stats on true
    left join lateral (
      select count(*)::integer as shipping_address_count
      from public.member_shipping_addresses msa
      where msa.user_id = mb.user_id
    ) address_stats on true
    left join lateral (
      select count(*)::integer as settlement_account_count
      from public.member_settlement_accounts msa
      where msa.user_id = mb.user_id
    ) account_stats on true
  )
  select jsonb_build_object(
    'member',
      (
        select jsonb_build_object(
          'user_id', mb.user_id,
          'email', mb.email,
          'name', mb.name,
          'nickname', mb.nickname,
          'display_name', mb.display_name,
          'phone', mb.phone,
          'marketing_opt_in', mb.marketing_opt_in,
          'email_verified_at', mb.email_verified_at,
          'joined_at', mb.joined_at,
          'created_at', mb.created_at,
          'updated_at', mb.updated_at,
          'last_sign_in_at', mb.last_sign_in_at,
          'is_staff', mb.is_staff,
          'pickup_count', s.pickup_count,
          'pickup_item_count', s.pickup_item_count,
          'order_count', s.order_count,
          'purchase_amount', s.purchase_amount,
          'settlement_count', s.settlement_count,
          'sale_amount', s.sale_amount,
          'net_settlement_amount', s.net_settlement_amount,
          'shipping_address_count', s.shipping_address_count,
          'settlement_account_count', s.settlement_account_count
        )
        from member_base mb
        join summary s
          on s.user_id = mb.user_id
      ),
    'shipping_addresses',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', msa.id,
              'label', msa.label,
              'recipient_name', msa.recipient_name,
              'recipient_phone', msa.recipient_phone,
              'postal_code', msa.postal_code,
              'address_line1', msa.address_line1,
              'address_line2', msa.address_line2,
              'delivery_memo', msa.delivery_memo,
              'is_default', msa.is_default,
              'created_at', msa.created_at,
              'updated_at', msa.updated_at
            )
            order by msa.is_default desc, msa.created_at desc, msa.id desc
          )
          from public.member_shipping_addresses msa
          where msa.user_id = p_user_id
        ),
        '[]'::jsonb
      ),
    'settlement_accounts',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', msa.id,
              'bank_name', msa.bank_name,
              'account_holder', msa.account_holder,
              'account_last4', right(regexp_replace(coalesce(msa.account_number, ''), '[^0-9]', '', 'g'), 4),
              'is_default', msa.is_default,
              'is_verified', msa.is_verified,
              'verified_at', msa.verified_at,
              'created_at', msa.created_at,
              'updated_at', msa.updated_at
            )
            order by msa.is_default desc, msa.created_at desc, msa.id desc
          )
          from public.member_settlement_accounts msa
          where msa.user_id = p_user_id
        ),
        '[]'::jsonb
      ),
    'pickups',
      coalesce(
        (
          select jsonb_agg(row_data.payload order by row_data.created_at desc, row_data.id desc)
          from (
            select
              pr.created_at,
              pr.id,
              jsonb_build_object(
                'source', 'pickup_request',
                'id', pr.id,
                'reference_number', pr.request_number,
                'status', pr.status,
                'item_count', pr.item_count,
                'tracking_number', pr.tracking_number,
                'tracking_carrier', pr.tracking_carrier,
                'created_at', pr.created_at,
                'updated_at', pr.updated_at,
                'items', coalesce(
                  (
                    select jsonb_agg(
                      jsonb_build_object(
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
                      )
                      order by pi.id
                    )
                    from public.pickup_items pi
                    where pi.pickup_request_id = pr.id
                  ),
                  '[]'::jsonb
                )
              ) as payload
            from public.pickup_requests pr
            where pr.user_id = p_user_id

            union all

            select
              sh.created_at,
              sh.id,
              jsonb_build_object(
                'source', 'shipment',
                'id', sh.id,
                'reference_number', 'SHIP-' || sh.id::text,
                'status', sh.status,
                'pickup_date', sh.pickup_date,
                'item_count', count(b.id)::integer,
                'created_at', sh.created_at,
                'updated_at', null,
                'items', coalesce(
                  jsonb_agg(
                    jsonb_build_object(
                      'id', b.id,
                      'title', b.title,
                      'option', b.option,
                      'status', b.status,
                      'condition_grade', b.condition_grade,
                      'price', b.price,
                      'original_price', b.original_price,
                      'is_public', b.is_public,
                      'created_at', b.created_at
                    )
                    order by b.id
                  ) filter (where b.id is not null),
                  '[]'::jsonb
                )
              ) as payload
            from public.shipments sh
            left join public.books b
              on b.shipment_id = sh.id
            where sh.user_id = p_user_id
            group by sh.id
          ) row_data
        ),
        '[]'::jsonb
      ),
    'orders',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', o.id,
              'order_number', o.order_number,
              'status', o.status,
              'payment_method', o.payment_method,
              'payment_status', o.payment_status,
              'subtotal', o.subtotal,
              'shipping_fee', o.shipping_fee,
              'discount_amount', o.discount_amount,
              'total_amount', o.total_amount,
              'item_count', o.item_count,
              'tracking_number', o.tracking_number,
              'tracking_carrier', o.tracking_carrier,
              'confirmed_at', o.confirmed_at,
              'auto_confirm_at', o.auto_confirm_at,
              'created_at', o.created_at,
              'updated_at', o.updated_at,
              'items', coalesce(
                (
                  select jsonb_agg(
                    jsonb_build_object(
                      'id', oi.id,
                      'book_id', oi.book_id,
                      'product_id', oi.product_id,
                      'title', oi.title,
                      'option_label', oi.option_label,
                      'condition_grade', oi.condition_grade,
                      'quantity', oi.quantity,
                      'unit_price', oi.unit_price,
                      'total_price', oi.total_price
                    )
                    order by oi.id
                  )
                  from public.order_items oi
                  where oi.order_id = o.id
                ),
                '[]'::jsonb
              )
            )
            order by o.created_at desc, o.id desc
          )
          from public.orders o
          where o.user_id = p_user_id
        ),
        '[]'::jsonb
      ),
    'settlements',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', st.id,
              'status', st.status,
              'order_id', st.order_id,
              'order_number', o.order_number,
              'order_item_id', st.order_item_id,
              'book_id', st.book_id,
              'book_title', coalesce(oi.title, b.title),
              'book_option', coalesce(oi.option_label, b.option),
              'condition_grade', coalesce(oi.condition_grade, b.condition_grade),
              'sale_amount', st.sale_amount,
              'fee_percent', st.fee_percent,
              'fee_amount', st.fee_amount,
              'net_amount', st.net_amount,
              'scheduled_date', st.scheduled_date,
              'approved_at', st.approved_at,
              'completed_at', st.completed_at,
              'bank_name', st.bank_name,
              'account_holder', st.account_holder,
              'account_last4', right(regexp_replace(coalesce(st.account_number, ''), '[^0-9]', '', 'g'), 4),
              'created_at', st.created_at,
              'updated_at', st.updated_at
            )
            order by coalesce(st.completed_at, st.approved_at, st.scheduled_date::timestamptz, st.created_at) desc, st.id desc
          )
          from public.settlements st
          join public.orders o
            on o.id = st.order_id
          left join public.order_items oi
            on oi.id = st.order_item_id
          join public.books b
            on b.id = st.book_id
          where st.seller_user_id = p_user_id
        ),
        '[]'::jsonb
      )
  )
  into v_result;

  if v_result -> 'member' is null or v_result -> 'member' = 'null'::jsonb then
    raise exception 'Member not found';
  end if;

  return v_result;
end;
$$;

create or replace function public.admin_block_member(
  p_user_id uuid,
  p_reason text default null,
  p_notify_user boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_email text;
  v_admin_user_id uuid;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_admin_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_admin_user_id := auth.uid();

  -- 운영진 계정 보호: admin_users 등록 이메일은 차단 금지.
  -- (차단은 auth 레벨 100년 밴이라 admin-web 로그인까지 잠긴다 — 사고 방지.
  --  회원 목록에 운영진이 노출되면서 차단 버튼 접근이 가능해진 것에 대한 서버측 가드)
  if exists (
    select 1
    from public.member_profiles mp
    join public.admin_users au
      on lower(au.email) = lower(mp.email)
    where mp.user_id = p_user_id
  ) then
    raise exception '운영진 계정은 차단할 수 없습니다.';
  end if;

  update public.member_profiles
  set
    is_blocked = true,
    blocked_at = now(),
    block_reason = nullif(btrim(p_reason), ''),
    updated_at = now()
  where user_id = p_user_id;

  if not found then
    raise exception '해당 회원을 찾을 수 없습니다.';
  end if;

  -- 진짜 로그인 차단: Supabase Auth 레벨 밴.
  -- 로그인 시도와 리프레시 토큰이 GoTrue에서 거부된다 (error code: user_banned).
  update auth.users
  set banned_until = now() + interval '100 years'
  where id = p_user_id;

  insert into public.member_block_history(
    target_user_id, admin_user_id, admin_email, action, reason, notify_user
  ) values (
    p_user_id, v_admin_user_id, v_admin_email, 'block', nullif(btrim(p_reason), ''), coalesce(p_notify_user, false)
  );

  return jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'is_blocked', true,
    'audit_logged', true
  );
end;
$$;

commit;
