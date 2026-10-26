-- 권별 수동 판매완료. 결제·정산 생성 없이 판매 재고만 내린다.
-- 기존 RLS/상태 파생/변경 이력 트리거를 유지하고 관리자만 호출할 수 있다.
-- 공식 문서: https://supabase.com/docs/guides/database/functions
-- 롤백: UI 버튼 제거 후 이 RPC만 제거. 이미 처리한 재고는 자동 복구하지 않는다.
begin;

create or replace function public.admin_mark_book_sold(p_book_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_book public.books%rowtype;
begin
  if not public.is_admin_user() then
    raise exception '관리자만 판매완료 처리할 수 있습니다.' using errcode = '42501';
  end if;

  -- 주문의 재고 선점과 직렬화하고 중복 클릭/응답 유실 재시도도 안전하게 처리한다.
  select * into v_book from public.books where id = p_book_id for update;
  if not found then
    raise exception '교재를 찾을 수 없습니다.';
  end if;
  if v_book.status = 'settled' then
    return jsonb_build_object('book_id', p_book_id, 'already_sold', true);
  end if;
  if v_book.status is distinct from 'on_sale' or v_book.condition_grade = 'DISCARD' then
    raise exception '판매중인 교재만 수동으로 판매완료 처리할 수 있습니다.';
  end if;

  -- 상태가 잘못 판매중으로 남은 경우에도 미취소·미환불 주문을 보호한다.
  if exists (
    select 1 from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where oi.book_id = p_book_id
      and oi.refunded_at is null
      and o.status not in ('cancelled', 'refunded')
  ) then
    raise exception '진행 중인 주문이 있는 교재입니다. 주문 화면에서 처리해 주세요.';
  end if;

  update public.books set status = 'settled', is_public = false where id = p_book_id;
  return jsonb_build_object('book_id', p_book_id, 'already_sold', false);
end;
$$;

revoke all on function public.admin_mark_book_sold(bigint) from public, anon;
grant execute on function public.admin_mark_book_sold(bigint) to authenticated, service_role;
commit;
