-- 쿠폰 삭제 RPC (2026-07-28 사용자 요청)
--
-- 기존엔 활성/비활성 토글만 있었음("delete 대신 — 발급분 보호"). 운영에서 잘못 만든/
-- 테스트 쿠폰을 정리할 방법이 없어 삭제를 추가하되, 감사 이력은 보호한다:
--   · 사용(used) 이력이 하나라도 있으면 삭제 거부 → 비활성화 안내
--     (used 행은 주문(used_order_id)과 연결된 회계 기록이라 지우면 안 됨)
--   · 미사용 발급분(available/expired)은 회원 쿠폰함에서 회수(삭제) 후 템플릿 삭제
--     — member_coupons.coupon_id FK가 ON DELETE RESTRICT라 순서 필수.
--
-- 비파괴 스키마: 신규 함수만 추가.

begin;

create or replace function public.admin_delete_coupon(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_used_count integer;
  v_reclaimed integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;

  select count(*) into v_used_count
  from public.member_coupons
  where coupon_id = p_coupon_id and status = 'used';

  if v_used_count > 0 then
    raise exception '사용 이력이 있는 쿠폰(%건)은 삭제할 수 없습니다. 대신 비활성화하세요.', v_used_count;
  end if;

  -- 미사용 발급분 회수 (회원 쿠폰함에서 사라짐)
  delete from public.member_coupons where coupon_id = p_coupon_id;
  get diagnostics v_reclaimed = row_count;

  delete from public.coupons where id = p_coupon_id;

  return jsonb_build_object(
    'success', true,
    'coupon_id', p_coupon_id,
    'reclaimed_count', v_reclaimed
  );
end;
$$;

grant execute on function public.admin_delete_coupon(bigint) to authenticated;

commit;

notify pgrst, 'reload schema';
