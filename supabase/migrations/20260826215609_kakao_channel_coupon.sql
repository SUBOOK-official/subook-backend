-- 카카오톡 채널 친구추가 3,000원 쿠폰 자동 발급 (2026-08-27)
--
-- 흐름: 홈 팝업 → pf.kakao.com 친구추가 → 채널 웰컴 메시지의 링크 → /event/kakao-coupon
--   → public-web 서버리스(api/event/kakao-coupon-claim)가 카카오 "채널 관계 확인" API
--     (어드민 키, GET kapi.kakao.com/v2/api/talk/channels)로 relation=ADDED를 검증한 뒤
--     service_role로 이 RPC를 호출해 발급한다.
--
-- 설계 결정:
--   · coupons.campaign_key: 서버 자동 발급 캠페인이 쿠폰을 안정적으로 특정하기 위한 키.
--     code(issuance_type='code') 방식을 쓰면 마이페이지 코드 입력으로 친추 검증 없이
--     등록할 수 있어 admin_assigned + campaign_key 조회 방식을 쓴다.
--   · RPC는 service_role 전용 — authenticated에 열면 클라이언트가 직접 호출해 친추
--     검증을 우회할 수 있으므로 grant를 service_role로 제한한다. (재정의 시 유지 필수)
--   · 1인 1매(발급 이력 있으면 거부), 지급일 +1일 만료 = 팝업 문구 "24시간 내 주문건 적용".
--
-- 비파괴: 컬럼 추가(additive) + 멱등 INSERT + CREATE FUNCTION.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) coupons.campaign_key
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.coupons
  add column if not exists campaign_key text null;

create unique index if not exists idx_coupons_campaign_key
  on public.coupons (campaign_key)
  where campaign_key is not null;

comment on column public.coupons.campaign_key is
  '서버 자동 발급 캠페인 식별 키 (예: kakao_channel_add). 발급 RPC가 이 키로 쿠폰을 특정한다.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 캠페인 쿠폰 정의 (멱등 — 이미 있으면 그대로 둠. 금액·기간 조정은 어드민 쿠폰 관리에서)
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.coupons (
  title, description, discount_type, discount_value, max_discount_amount,
  min_order_amount, valid_from, valid_until, valid_days,
  usage_limit_per_user, total_quantity, issuance_type, is_active, campaign_key
)
select
  '카카오톡 채널 친구추가 3,000원 할인',
  '카카오톡 채널 친구추가 확인 시 자동 발급됩니다. 1인 1매 자동 관리 — 어드민 수동 발급 금지.',
  'fixed', 3000, null,
  0, null, null, 1,
  1, null, 'admin_assigned', true, 'kakao_channel_add'
where not exists (
  select 1 from public.coupons where campaign_key = 'kakao_channel_add'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 발급 RPC — service_role 전용
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.claim_kakao_channel_coupon(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_blocked boolean;
  v_member_coupon_id bigint;
  v_expires_at timestamptz;
begin
  if p_user_id is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_USER');
  end if;

  -- 쿠폰 행 잠금 — 동시 발급 직렬화 (1인 1매 검사와 issued_count 증가를 같은 락 안에서)
  select * into v_coupon
  from public.coupons
  where campaign_key = 'kakao_channel_add'
  for update;

  if not found or not v_coupon.is_active then
    return jsonb_build_object('success', false, 'code', 'NOT_CONFIGURED');
  end if;
  if v_coupon.valid_from is not null and v_coupon.valid_from > now() then
    return jsonb_build_object('success', false, 'code', 'NOT_STARTED');
  end if;
  if v_coupon.valid_until is not null and v_coupon.valid_until < now() then
    return jsonb_build_object('success', false, 'code', 'ENDED');
  end if;

  -- 회원 존재 + 차단 확인
  select coalesce(is_blocked, false) into v_blocked
  from public.member_profiles
  where user_id = p_user_id;
  if not found then
    return jsonb_build_object('success', false, 'code', 'NOT_MEMBER');
  end if;
  if v_blocked then
    return jsonb_build_object('success', false, 'code', 'BLOCKED');
  end if;

  -- 1인 1매 (친구 삭제 후 재추가해도 재발급 안 됨)
  if exists (
    select 1 from public.member_coupons
    where coupon_id = v_coupon.id and user_id = p_user_id
  ) then
    return jsonb_build_object('success', false, 'code', 'ALREADY_CLAIMED');
  end if;

  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    return jsonb_build_object('success', false, 'code', 'SOLD_OUT');
  end if;

  v_expires_at := public.compute_coupon_member_expiry(v_coupon.valid_days, v_coupon.valid_until);

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (v_coupon.id, p_user_id, v_expires_at)
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = v_coupon.id;

  return jsonb_build_object(
    'success', true,
    'code', 'ISSUED',
    'member_coupon_id', v_member_coupon_id,
    'expires_at', v_expires_at
  );
end;
$$;

revoke all on function public.claim_kakao_channel_coupon(uuid) from public;
revoke all on function public.claim_kakao_channel_coupon(uuid) from anon;
revoke all on function public.claim_kakao_channel_coupon(uuid) from authenticated;
grant execute on function public.claim_kakao_channel_coupon(uuid) to service_role;

commit;
