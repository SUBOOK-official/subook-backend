-- 반품 회수 보류(restock_held_at)가 전액 환불에서 무력화되던 버그 수리.
--
-- 사고(2026-08-25, ORD-2608-0126 / 책 3403):
--   admin_refund_order(p_restock=false)가 order_items.restock_held_at을 스탬프한 직후
--   orders.status를 'refunded'로 바꾸는데, 그 순간 trg_release_books_on_order_cancel
--   (20260531030000, AFTER UPDATE OF status)가 보류 스탬프를 모른 채 reserved 책을
--   on_sale+is_public으로 풀어버렸다(같은 트랜잭션·같은 타임스탬프). 결과:
--     - 실물이 구매자 집에 있는데 스토어에 재노출 (보류의 목적 자체가 무너짐)
--     - 회수 후 '회수 완료' 버튼(admin_confirm_return_recovery)이 b.status='reserved'
--       조건에 걸려 "회수 보류 중인 책이 없습니다"로 영구 실패 → 어드민이 보류를 닫을 수 없음
--   부분환불(주문 상태 전이 없음)은 영향 없음.
--
-- 수리:
--   1) release_books_on_order_cancel — 이번 주문에서 restock_held_at이 찍힌 책은 복원 제외.
--      (회수 확인 RPC가 복원/폐기의 단일 경로가 되도록)
--   2) admin_confirm_return_recovery — 보류 품목 기준으로 동작하고, 책의 현재 상태에 따라
--      처리(reserved→복원/폐기, 이미 on_sale→복원은 no-op·폐기는 수행, 타 주문이 잡았거나
--      sold/settled/discarded면 건드리지 않고 skipped로 보고). 보류 품목이 있으면 예외 대신
--      항상 보류 해제+return_recovered_at 스탬프 → 어드민이 보류를 닫을 수 있다.
--   3) 데이터 보정 없음 — ORD-2608-0126은 새 RPC로 어드민이 '회수 완료' 버튼을 눌러 닫는다
--      (책 3403은 이미 on_sale·다른 활성 주문 없음 확인, 2026-09-02).
--
-- 비파괴: CREATE OR REPLACE FUNCTION 2건만. 트리거 정의·시그니처·grant 변경 없음.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 주문 취소/환불 시 책 복원 트리거 — 회수 보류 품목 제외
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.release_books_on_order_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('cancelled', 'refunded')
     and old.status not in ('cancelled', 'refunded') then
    -- status='on_sale'과 함께 is_public=true 복원 필수.
    -- books_enforce_public_storefront_rules 트리거가 reserved 전환 시 is_public=false로
    -- 강제했으므로(20260525200000 참고), on_sale로만 되돌리면 storefront에 안 잡힌다.
    update public.books b
    set status = 'on_sale', is_public = true
    where b.id in (
        select oi.book_id from public.order_items oi where oi.order_id = new.id
      )
      and b.status = 'reserved'
      -- 반품 회수 보류(20260824063025): 실물 미회수 책은 풀지 않는다.
      -- 회수 후 admin_confirm_return_recovery가 복원/폐기의 단일 경로.
      and not exists (
        select 1
        from public.order_items oih
        where oih.order_id = new.id
          and oih.book_id = b.id
          and oih.restock_held_at is not null
      )
      and not exists (
        -- 같은 책에 다른 active(미취소/미환불) order가 있으면 복원하지 않음
        select 1
        from public.order_items oi2
        inner join public.orders o2 on o2.id = oi2.order_id
        where oi2.book_id = b.id
          and o2.id <> new.id
          and o2.status not in ('cancelled', 'refunded')
      );
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 회수 확인 RPC — 보류 품목 기준, 책 현재 상태별 처리
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_confirm_return_recovery(
  p_order_id bigint,
  p_outcome text default 'restock'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_held_book_ids bigint[];
  v_book_ids bigint[];
  v_skipped_book_ids bigint[];
  v_already_on_sale integer := 0;
  v_updated_books integer := 0;
  v_cleared_items integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if p_outcome not in ('restock', 'discard') then
    raise exception '알 수 없는 처리 방식입니다: % (restock 또는 discard)', p_outcome;
  end if;

  perform 1 from public.orders where id = p_order_id for update;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  -- 보류 품목(= 회수 대상). 책 상태와 무관하게 "보류가 걸려 있는가"가 기준.
  select coalesce(array_agg(distinct oi.book_id), '{}'::bigint[])
    into v_held_book_ids
    from public.order_items oi
   where oi.order_id = p_order_id
     and oi.restock_held_at is not null;

  if coalesce(array_length(v_held_book_ids, 1), 0) = 0 then
    raise exception '회수 보류 중인 책이 없습니다.';
  end if;

  -- 처리 가능한 책: 이 주문 소유의 reserved 또는 (트리거 버그 등으로) 이미 풀린 on_sale.
  -- 다른 활성 주문이 잡고 있거나 sold/settled/discarded면 건드리지 않는다(skipped).
  select coalesce(array_agg(b.id), '{}'::bigint[])
    into v_book_ids
    from public.books b
   where b.id = any(v_held_book_ids)
     and b.status in ('reserved', 'on_sale')
     and not exists (
       select 1
       from public.order_items oi2
       inner join public.orders o2 on o2.id = oi2.order_id
       where oi2.book_id = b.id
         and o2.id <> p_order_id
         and o2.status not in ('cancelled', 'refunded')
         and oi2.refunded_at is null
     );

  select coalesce(array_agg(x), '{}'::bigint[])
    into v_skipped_book_ids
    from unnest(v_held_book_ids) as x
   where not (x = any(v_book_ids));

  if p_outcome = 'restock' then
    select count(*) into v_already_on_sale
      from public.books
     where id = any(v_book_ids) and status = 'on_sale';

    update public.books
       set status = 'on_sale', is_public = true
     where id = any(v_book_ids)
       and status = 'reserved';
  else
    -- 폐기: 회수한 실물이 훼손 등으로 재판매 불가한 경우. 이미 풀린 on_sale 책도 폐기.
    -- (books_assert_no_active_order_on_discard 가드는 환불된 품목을 활성으로 세지 않음 — 20260824063025 5번)
    update public.books
       set status = 'discarded', is_public = false
     where id = any(v_book_ids)
       and status in ('reserved', 'on_sale');
  end if;
  get diagnostics v_updated_books = row_count;

  update public.order_items
     set restock_held_at = null
   where order_id = p_order_id
     and restock_held_at is not null;
  get diagnostics v_cleared_items = row_count;

  update public.orders
     set return_recovered_at = v_now,
         updated_at = v_now
   where id = p_order_id;

  return jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'outcome', p_outcome,
    'updated_books', v_updated_books,
    'already_on_sale', v_already_on_sale,
    'skipped_book_ids', to_jsonb(v_skipped_book_ids),
    'cleared_items', v_cleared_items,
    'recovered_at', v_now
  );
end;
$$;

grant execute on function public.admin_confirm_return_recovery(bigint, text) to authenticated;

commit;
