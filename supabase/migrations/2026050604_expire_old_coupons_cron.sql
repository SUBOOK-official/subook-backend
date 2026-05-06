-- 쿠폰 시스템 PR 4: 만료 처리 cron + 어드민 발급 이력 통계
-- expire_old_coupons RPC: status='available'이면서 expires_at이 지난 행을 batch로 'expired' 갱신
-- (member_coupons 테이블의 status는 SELECT 시점에 effective_status로 즉시 반영되지만,
--  cron으로 batch 갱신해두면 인덱스 효율 ↑ + 통계 RPC가 정확해짐)

create or replace function public.expire_old_coupons()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_count integer;
begin
  update public.member_coupons
  set status = 'expired'
  where status = 'available'
    and expires_at is not null
    and expires_at < now();

  get diagnostics v_expired_count = row_count;

  return jsonb_build_object(
    'success', true,
    'expired_count', v_expired_count,
    'executed_at', now()
  );
end;
$$;

-- 쿠폰 통계: 발급 / 사용 / 만료 / 잔여
-- 어드민 페이지의 발급 이력 모달 상단에서 사용
create or replace function public.admin_get_coupon_stats(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_total integer;
  v_used integer;
  v_expired integer;
  v_available integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;

  select count(*) into v_total
    from public.member_coupons where coupon_id = p_coupon_id;
  select count(*) into v_used
    from public.member_coupons where coupon_id = p_coupon_id and status = 'used';
  select count(*) into v_expired
    from public.member_coupons
    where coupon_id = p_coupon_id
      and (status = 'expired'
           or (status = 'available' and expires_at is not null and expires_at < now()));
  v_available := v_total - v_used - v_expired;

  return jsonb_build_object(
    'coupon_id', p_coupon_id,
    'total_issued', v_total,
    'used_count', v_used,
    'expired_count', v_expired,
    'available_count', v_available,
    'remaining_quota', case
      when v_coupon.total_quantity is null then null
      else greatest(0, v_coupon.total_quantity - v_coupon.issued_count)
    end
  );
end;
$$;

grant execute on function public.expire_old_coupons() to authenticated;
grant execute on function public.admin_get_coupon_stats(bigint) to authenticated;
