-- TIER 2-1: Admin 회원 관리
-- 회원 목록 검색과 회원별 수거/주문/정산 통합 상세 조회 RPC를 제공한다.

create index if not exists idx_member_profiles_admin_name_lower
  on public.member_profiles (lower(name));

create index if not exists idx_member_profiles_admin_phone
  on public.member_profiles (phone);

create or replace function public.list_admin_members(
  p_search text default null,
  p_limit integer default 50,
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

  with params as (
    select
      btrim(coalesce(p_search, '')) as search_term,
      regexp_replace(btrim(coalesce(p_search, '')), '[^0-9]', '', 'g') as search_digits
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
      mp.updated_at
    from public.member_profiles mp
    left join auth.users au
      on au.id = mp.user_id
    cross join params
    where not exists (
        select 1
        from public.admin_users admin_user
        where lower(admin_user.email) = lower(mp.email)
      )
      and (
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
  page_rows as (
    select *
    from enriched
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
    'total_count', (select count(*) from enriched),
    'summary',
      jsonb_build_object(
        'member_count', (select count(*) from enriched),
        'new_member_count_30d', (
          select count(*)
          from enriched
          where joined_at >= now() - interval '30 days'
        ),
        'purchase_amount', coalesce((select sum(purchase_amount) from enriched), 0),
        'sale_amount', coalesce((select sum(sale_amount) from enriched), 0),
        'pickup_count', coalesce((select sum(pickup_request_count + legacy_shipment_count) from enriched), 0),
        'order_count', coalesce((select sum(order_count) from enriched), 0)
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
      au.last_sign_in_at
    from public.member_profiles mp
    left join auth.users au
      on au.id = mp.user_id
    where mp.user_id = p_user_id
      and not exists (
        select 1
        from public.admin_users admin_user
        where lower(admin_user.email) = lower(mp.email)
      )
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

grant execute on function public.list_admin_members(text, integer, integer) to authenticated;
grant execute on function public.get_admin_member_detail(uuid) to authenticated;
