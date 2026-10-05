-- 구매자가 선택한 주문 품목을 사유와 별도로 보존한다. 기존 신청은 추정해 채우지 않는다.
-- RLS 참고: https://supabase.com/docs/guides/database/postgres/row-level-security
create table public.order_refund_request_items (
  order_item_id bigint primary key references public.order_items(id) on delete cascade,
  order_id bigint not null references public.orders(id) on delete cascade,
  requested_at timestamptz not null default now()
);
create index order_refund_request_items_order_idx on public.order_refund_request_items(order_id);
alter table public.order_refund_request_items enable row level security;
revoke all on public.order_refund_request_items from public, anon, authenticated;
grant select on public.order_refund_request_items to authenticated;
grant all on public.order_refund_request_items to service_role;
create policy refund_request_items_read on public.order_refund_request_items
  for select to authenticated using (
    public.is_admin_user() or exists (
      select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid())
    )
  );

create or replace function public.request_member_refund(p_order_id bigint, p_reason text, p_item_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid := auth.uid();
  v_order public.orders%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_now timestamptz := now();
  v_item_ids bigint[];
  v_count integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if v_reason is null or length(v_reason) < 4 then
    raise exception '환불 사유는 4자 이상 입력해주세요.';
  end if;
  select * into v_order from public.orders
    where id = p_order_id and user_id = v_user_id for update;
  if not found then raise exception '주문을 찾을 수 없습니다.'; end if;
  if v_order.status not in ('delivered', 'confirmed') then
    raise exception '배송완료 또는 구매확정 상태에서만 환불을 신청할 수 있습니다. (현재: %)', v_order.status;
  end if;
  if v_order.refund_requested_at is not null then
    raise exception '이미 환불 신청이 접수되었습니다. (접수일: %)', to_char(v_order.refund_requested_at, 'YYYY-MM-DD HH24:MI');
  end if;
  if v_order.status = 'delivered' and coalesce(v_order.updated_at, v_order.created_at) < v_now - interval '7 days' then
    raise exception '배송완료 후 7일이 지나 환불 신청이 어렵습니다. 고객센터에 문의해주세요.';
  end if;
  if v_order.status = 'confirmed' then
    raise exception '구매확정된 주문은 셀프 환불 신청이 어렵습니다. 카카오톡 채널 또는 고객센터(subook2025@gmail.com)로 문의해주세요.';
  end if;

  if coalesce(cardinality(p_item_ids), 0) = 0 or array_position(p_item_ids, null) is not null then
    raise exception '환불할 교재를 한 권 이상 선택해주세요.';
  end if;
  select array_agg(distinct id order by id) into v_item_ids from unnest(p_item_ids) as selected(id);
  -- 주문 잠금 후 품목을 고정: 다른 주문 품목·이미 환불된 품목은 하나라도 섞이면 전체 실패.
  perform 1 from public.order_items where order_id = p_order_id and id = any(v_item_ids) for update;
  select count(*) into v_count from public.order_items
    where order_id = p_order_id and id = any(v_item_ids) and refunded_at is null;
  if v_count <> cardinality(v_item_ids) then
    raise exception '선택한 교재가 이 주문에 없거나 이미 환불되었습니다. 새로고침 후 다시 선택해주세요.';
  end if;

  insert into public.order_refund_request_items(order_id, order_item_id, requested_at)
    select p_order_id, id, v_now from unnest(v_item_ids) as selected(id);
  -- 기존 자동확정·정산 보류 계약 유지. 품목 저장과 신청 접수는 한 트랜잭션이다.
  update public.orders set refund_requested_at = v_now, refund_request_reason = v_reason, updated_at = v_now
    where id = p_order_id;
  return jsonb_build_object('success', true, 'order_id', p_order_id, 'requested_at', v_now,
    'reason', v_reason, 'item_ids', v_item_ids);
end;
$$;
revoke all on function public.request_member_refund(bigint,text,bigint[]) from public, anon;
grant execute on function public.request_member_refund(bigint,text,bigint[]) to authenticated;

-- 캐시된 구버전 화면도 대상 없는 신청을 생성하지 못하도록 안내한다.
create or replace function public.request_member_refund(p_order_id bigint, p_reason text)
returns jsonb language plpgsql set search_path = public as $$
begin
  raise exception '환불 교재 선택 기능이 업데이트되었습니다. 화면을 새로고침한 후 대상 교재를 선택해주세요.';
end;
$$;
revoke all on function public.request_member_refund(bigint,text) from public, anon;
grant execute on function public.request_member_refund(bigint,text) to authenticated;

-- 롤백: 앱을 되돌릴 경우 기존 2인자 함수 본문을 복원한다. 신청 품목 테이블은 이력 보존을 위해 유지한다.
