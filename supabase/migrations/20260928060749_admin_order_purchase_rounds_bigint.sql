-- 운영 orders.id는 bigint다. 프론트 배포 전에 잘못된 UUID 오버로드를 교체한다.
-- 새 조회 함수만 교체하며 주문 데이터와 기존 RLS는 변경하지 않는다.
begin;

drop function public.admin_order_purchase_rounds(uuid[]);

create or replace function public.admin_order_purchase_rounds(p_order_ids bigint[])
returns jsonb
language plpgsql stable security definer
set search_path = ''
set statement_timeout = '8s'
as $function$
declare
  v_result jsonb;
begin
  if not coalesce(public.is_admin_user(), false) then
    raise exception '관리자만 조회할 수 있습니다.' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_order_ids), 0) > 100 then
    raise exception '한 번에 최대 100개 주문을 조회할 수 있습니다.' using errcode = '22023';
  end if;

  with requested as (
    select o.id, o.user_id,
      nullif(regexp_replace(o.shipping_recipient_phone, '[^0-9]', '', 'g'), '') as guest_phone,
      coalesce(o.paid_at, o.pg_approved_at, o.created_at) as order_time
    from public.orders o
    where o.id = any(p_order_ids)
  )
  select coalesce(jsonb_object_agg(o.id::text, 1 + (
    select count(*)
    from public.orders h
    where h.id <> o.id
      and h.payment_status in ('paid', 'refunded')
      and (coalesce(h.paid_at, h.pg_approved_at), h.id) < (o.order_time, o.id)
      and (
        (o.user_id is not null and h.user_id = o.user_id)
        or (o.user_id is null and h.user_id is null and o.guest_phone is not null
          and nullif(regexp_replace(h.shipping_recipient_phone, '[^0-9]', '', 'g'), '') = o.guest_phone)
      )
  )), '{}'::jsonb)
  into v_result
  from requested o;

  return v_result;
end;
$function$;

revoke all on function public.admin_order_purchase_rounds(bigint[]) from public, anon;
grant execute on function public.admin_order_purchase_rounds(bigint[]) to authenticated;
comment on function public.admin_order_purchase_rounds(bigint[]) is
  '관리자 주문별 구매 차수. 이전 결제 이력(환불 포함)+현재 주문 1회, 회원/비회원 분리. 미결제 주문은 생성 시각 기준.';

commit;
