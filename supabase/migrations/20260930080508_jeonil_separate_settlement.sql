-- 전일학원 자체판매분 별도 정산: 사용자 확정 50%, 2026-09-30 이전 지급 내역 없음.
-- 기존 셀러 정산·주문·재고·환불 함수는 변경하지 않는다.
-- 롤백: 화면 연결을 먼저 해제하고 이 원장은 보존한다. 실제 지급 기록 삭제 금지.
begin;

create table public.jeonil_settlement_payments (
  order_item_id bigint primary key references public.order_items(id),
  order_id bigint not null references public.orders(id),
  book_id bigint not null references public.books(id),
  product_id bigint,
  book_title text not null,
  book_option text,
  quantity integer not null check (quantity > 0),
  sale_amount bigint not null check (sale_amount >= 0),
  fee_percent integer not null default 50 check (fee_percent = 50),
  fee_amount bigint not null check (fee_amount >= 0),
  net_amount bigint not null check (net_amount >= 0 and net_amount + fee_amount = sale_amount),
  completed_at timestamptz not null default now(),
  completed_by uuid not null,
  transfer_reference text not null check (length(btrim(transfer_reference)) between 2 and 500)
);
alter table public.jeonil_settlement_payments enable row level security;
revoke all on public.jeonil_settlement_payments from anon, authenticated;
grant select on public.jeonil_settlement_payments to authenticated;
create policy jeonil_payments_admin_read on public.jeonil_settlement_payments
  for select to authenticated using (public.is_admin_user());

-- 내부 조회 전용. 공개 RPC에서 관리자 검증 후 실행하며 직접 호출 권한은 주지 않는다.
create function public.jeonil_settlement_candidates()
returns table (
  order_item_id bigint, order_id bigint, order_number text, book_id bigint, product_id bigint,
  book_title text, book_option text, quantity integer, sale_amount bigint,
  fee_amount bigint, net_amount bigint, confirmed_at timestamptz,
  is_payable boolean, hold_reason text
)
language sql stable set search_path = '' as $$
  select i.id, i.order_id, o.order_number, i.book_id, i.product_id,
    coalesce(i.title, b.title, '전일학원 모의고사'), i.option_label, greatest(1, coalesce(i.quantity, 1)),
    price.sale_amount, round(price.sale_amount * 0.5)::bigint,
    price.sale_amount - round(price.sale_amount * 0.5)::bigint, o.confirmed_at,
    o.status = 'confirmed' and not hold.is_held,
    case when hold.is_held then '환불 처리 대기' when o.status <> 'confirmed' then '구매확정 대기' else null end
  from public.order_items i
  join public.orders o on o.id = i.order_id
  join public.books b on b.id = i.book_id
  cross join lateral (select greatest(0, coalesce(i.total_price, i.unit_price * greatest(1, coalesce(i.quantity, 1)), 0))::bigint as sale_amount) price
  cross join lateral (select
    (o.refund_requested_at is not null and o.refund_request_resolved_at is null)
    or exists (select 1 from public.order_return_cases rc where rc.order_id = o.id and rc.status not in ('refunded', 'cancelled')) as is_held
  ) hold
  where b.brand = '전일학원' and b.shipment_id is null
    and o.payment_status = 'paid' and o.status in ('paid', 'preparing', 'shipping', 'delivered', 'confirmed')
    and i.refunded_at is null
    and not exists (select 1 from public.jeonil_settlement_payments jp where jp.order_item_id = i.id)
    and not exists (select 1 from public.settlements st where st.order_id = o.id and st.book_id = i.book_id and st.status <> 'cancelled')
    and not exists (select 1 from public.manual_settlements ms where ms.book_id = i.book_id and ms.status <> 'cancelled');
$$;
revoke all on function public.jeonil_settlement_candidates() from public, anon, authenticated;

create function public.admin_get_jeonil_settlements()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_result jsonb;
begin
  if not coalesce(public.is_admin_user(), false) then raise exception 'Admin access required' using errcode = '42501'; end if;
  with unpaid as materialized (select * from public.jeonil_settlement_candidates()),
  completed as (
    select jp.*, o.order_number,
      i.refunded_at is not null or o.payment_status = 'refunded' or o.status = 'refunded' as refunded_after_payment
    from public.jeonil_settlement_payments jp
    join public.orders o on o.id = jp.order_id
    join public.order_items i on i.id = jp.order_item_id
  )
  select jsonb_build_object(
    'payable', coalesce((select jsonb_agg(to_jsonb(u) order by u.confirmed_at, u.order_item_id) from unpaid u where u.is_payable), '[]'::jsonb),
    'waiting', coalesce((select jsonb_agg(to_jsonb(u) order by u.order_item_id) from unpaid u where not u.is_payable), '[]'::jsonb),
    'completed', coalesce((select jsonb_agg(to_jsonb(c) order by c.completed_at desc, c.order_item_id) from completed c), '[]'::jsonb),
    'fee_percent', 50
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_get_jeonil_settlements() from public, anon, authenticated;
grant execute on function public.admin_get_jeonil_settlements() to authenticated;

create function public.admin_complete_jeonil_settlements(
  p_order_item_ids bigint[], p_expected_amount bigint, p_transfer_reference text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_count integer; v_amount bigint; v_expected_count integer; v_completed integer;
begin
  if not coalesce(public.is_admin_user(), false) or auth.uid() is null then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_order_item_ids), 0) = 0 or cardinality(p_order_item_ids) > 2000
    or nullif(btrim(p_transfer_reference), '') is null or length(btrim(p_transfer_reference)) not between 2 and 500
    or p_expected_amount is null or p_expected_amount < 0 then
    raise exception '지급 대상과 이체 메모를 확인해 주세요.';
  end if;
  select count(distinct id) into v_expected_count from unnest(p_order_item_ids) as t(id);
  if v_expected_count <> cardinality(p_order_item_ids) then raise exception '중복되거나 잘못된 지급 대상입니다.'; end if;

  -- 환불·구매확정이 사용하는 주문 잠금과 같은 순서로 잠근다. 중복 요청도 직렬화된다.
  perform o.id from public.orders o
  where o.id in (select i.order_id from public.order_items i where i.id = any(p_order_item_ids))
  order by o.id for update;
  perform i.id from public.order_items i where i.id = any(p_order_item_ids) order by i.id for update;

  select count(*), coalesce(sum(c.net_amount), 0) into v_count, v_amount
  from public.jeonil_settlement_candidates() c where c.order_item_id = any(p_order_item_ids) and c.is_payable;
  if v_count <> v_expected_count or v_amount <> p_expected_amount then
    raise exception '정산 대상 또는 금액이 변경됐습니다. 새로고침 후 지급 내역을 확인해 주세요.';
  end if;

  insert into public.jeonil_settlement_payments
    (order_item_id, order_id, book_id, product_id, book_title, book_option, quantity, sale_amount, fee_amount, net_amount, completed_by, transfer_reference)
  select c.order_item_id, c.order_id, c.book_id, c.product_id, c.book_title, c.book_option, c.quantity,
    c.sale_amount, c.fee_amount, c.net_amount, auth.uid(), btrim(p_transfer_reference)
  from public.jeonil_settlement_candidates() c where c.order_item_id = any(p_order_item_ids) and c.is_payable;
  get diagnostics v_completed = row_count;
  if v_completed <> v_expected_count then raise exception '정산 대상이 변경됐습니다. 새로고침해 주세요.'; end if;
  return jsonb_build_object('updated_count', v_completed, 'net_amount', v_amount);
end;
$$;
revoke all on function public.admin_complete_jeonil_settlements(bigint[], bigint, text) from public, anon, authenticated;
grant execute on function public.admin_complete_jeonil_settlements(bigint[], bigint, text) to authenticated;

comment on table public.jeonil_settlement_payments is '전일학원 원장 지급 기록. 수수료 50%, 주문 상품금액 기준(쿠폰·포인트 차감 전), 배송비·박스비 제외. 주문 품목당 한 번만 지급.';
notify pgrst, 'reload schema';
commit;
