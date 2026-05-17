-- 어드민 일괄 작업 RPC 7종 (P3 Sprint 2-3)
--
-- 주문: admin_bulk_update_order_status(ids, p_status)
-- 상품 마스터: admin_bulk_update_product_status(ids, p_status),
--             admin_bulk_delete_products(ids)
-- 책: admin_bulk_update_books_status(ids, p_status),
--    admin_bulk_update_books_price_delta(ids, p_delta_percent),
--    admin_bulk_update_books_price_absolute(ids, p_price)
-- 수거: admin_bulk_cancel_pickup_requests(ids, p_reason)
--
-- 모두 SECURITY DEFINER + is_admin_user() 가드. 각 RPC는 result jsonb에 처리/실패 건수.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 주문 일괄 상태 변경
--    화이트리스트: preparing/cancelled만 일괄 허용 (paid → confirmed 점프는 금지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_order_status(
  p_ids bigint[],
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_success_count integer := 0;
  v_fail_count integer := 0;
  v_failures jsonb := '[]'::jsonb;
  v_msg text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_status not in ('preparing', 'cancelled') then
    raise exception '일괄 변경은 preparing/cancelled만 허용됩니다. (입력: %)', p_status;
  end if;

  foreach v_id in array p_ids loop
    begin
      perform public.admin_update_order_status(v_id, p_status, null, null);
      v_success_count := v_success_count + 1;
    exception when others then
      v_fail_count := v_fail_count + 1;
      v_msg := sqlerrm;
      v_failures := v_failures || jsonb_build_object('id', v_id, 'reason', v_msg);
    end;
  end loop;

  return jsonb_build_object(
    'success', true,
    'success_count', v_success_count,
    'fail_count', v_fail_count,
    'failures', v_failures
  );
end;
$$;

grant execute on function public.admin_bulk_update_order_status(bigint[], text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 상품 마스터 일괄 상태 변경 (selling / sold_out / hidden)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_product_status(
  p_ids bigint[],
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_status not in ('selling', 'sold_out', 'hidden') then
    raise exception 'products.status는 selling/sold_out/hidden만 허용됩니다.';
  end if;

  update public.products
  set status = p_status, updated_at = now()
  where id = any(p_ids);

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'updated_count', v_updated_count);
end;
$$;

grant execute on function public.admin_bulk_update_product_status(bigint[], text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 상품 마스터 일괄 삭제 (active books 있으면 reject)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_delete_products(
  p_ids bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_blocked_ids bigint[];
  v_deleted_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- 연결된 books가 있는 product는 차단
  select coalesce(array_agg(distinct b.product_id), '{}')
    into v_blocked_ids
  from public.books b
  where b.product_id = any(p_ids);

  delete from public.products
  where id = any(p_ids)
    and id <> all(coalesce(v_blocked_ids, '{}'::bigint[]));

  get diagnostics v_deleted_count = row_count;

  return jsonb_build_object(
    'success', true,
    'deleted_count', v_deleted_count,
    'blocked_count', coalesce(array_length(v_blocked_ids, 1), 0),
    'blocked_ids', to_jsonb(v_blocked_ids)
  );
end;
$$;

grant execute on function public.admin_bulk_delete_products(bigint[]) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 책 일괄 상태 변경 (on_sale / settled / discarded)
--    active order 있는 책의 discarded 전환은 트리거(2026051506)가 차단함
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_books_status(
  p_ids bigint[],
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_success_count integer := 0;
  v_fail_count integer := 0;
  v_failures jsonb := '[]'::jsonb;
  v_msg text;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_status not in ('on_sale', 'settled', 'discarded') then
    raise exception 'books.status는 on_sale/settled/discarded만 허용됩니다.';
  end if;

  foreach v_id in array p_ids loop
    begin
      update public.books set status = p_status where id = v_id;
      if found then v_success_count := v_success_count + 1;
      else v_fail_count := v_fail_count + 1;
           v_failures := v_failures || jsonb_build_object('id', v_id, 'reason', 'not found');
      end if;
    exception when others then
      v_fail_count := v_fail_count + 1;
      v_msg := sqlerrm;
      v_failures := v_failures || jsonb_build_object('id', v_id, 'reason', v_msg);
    end;
  end loop;

  return jsonb_build_object(
    'success', true,
    'success_count', v_success_count,
    'fail_count', v_fail_count,
    'failures', v_failures
  );
end;
$$;

grant execute on function public.admin_bulk_update_books_status(bigint[], text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) 책 일괄 공개/숨김 (is_public 토글)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_books_visibility(
  p_ids bigint[],
  p_is_public boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  update public.books
  set is_public = coalesce(p_is_public, false)
  where id = any(p_ids);

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'updated_count', v_updated_count);
end;
$$;

grant execute on function public.admin_bulk_update_books_visibility(bigint[], boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) 책 일괄 가격 변경 (percent delta — 예: -10% 할인)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_update_books_price_delta(
  p_ids bigint[],
  p_delta_percent numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
  v_factor numeric;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_delta_percent is null or p_delta_percent < -100 or p_delta_percent > 1000 then
    raise exception '할인/인상률은 -100 ~ 1000 사이여야 합니다.';
  end if;

  v_factor := 1 + (p_delta_percent / 100.0);

  update public.books
  set price = greatest(0, round(coalesce(price, 0) * v_factor)::integer)
  where id = any(p_ids)
    and price is not null;

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'updated_count', v_updated_count,
                            'delta_percent', p_delta_percent);
end;
$$;

grant execute on function public.admin_bulk_update_books_price_delta(bigint[], numeric) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) 수거 요청 일괄 취소
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bulk_cancel_pickup_requests(
  p_ids bigint[],
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  -- p_reason은 추후 admin_memo 컬럼 도입 시 활용 (현재 미사용, signature 호환)
  perform p_reason;

  update public.pickup_requests
  set
    status = 'cancelled',
    updated_at = now()
  where id = any(p_ids)
    and status in ('pending', 'pickup_assigned');

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object('success', true, 'cancelled_count', v_updated_count);
end;
$$;

grant execute on function public.admin_bulk_cancel_pickup_requests(bigint[], text) to authenticated;

commit;
