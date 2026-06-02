-- confirm_member_purchase를 (2026041202의 정본 정의 그대로) CREATE OR REPLACE + grant.
-- 목적 2가지:
--  1) authenticated EXECUTE grant 보장 (구매자 구매확정 404 수정).
--  2) CREATE OR REPLACE는 Supabase의 DDL 이벤트 트리거(pgrst_ddl_watch)가 잡아
--     PostgREST 스키마 캐시를 즉시 리로드시킨다 — 직전 grant-only 마이그레이션은
--     pooler(PgBouncer) 경유라 NOTIFY가 PostgREST에 닿지 않아 캐시에 반영되지 않았다.
-- 정의는 변경 없음(현재 정본 = 2026041202; 이후 재정의된 적 없음).

create or replace function public.confirm_member_purchase(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_order record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_order from public.orders where id = p_order_id and user_id = v_user_id;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status != 'delivered' then
    raise exception '배송완료 상태에서만 구매확정이 가능합니다. (현재: %)', v_order.status;
  end if;

  if v_order.confirmed_at is not null then
    raise exception '이미 구매확정된 주문입니다.';
  end if;

  update public.orders
  set
    status = 'confirmed',
    confirmed_at = now(),
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

grant execute on function public.confirm_member_purchase(bigint) to authenticated;
