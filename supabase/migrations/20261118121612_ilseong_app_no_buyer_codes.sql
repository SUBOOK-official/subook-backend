-- 2026-11-18 일성월심 앱 코드를 구매자에게 내보내지 않는다.
--
-- 까닭: 앱에서 코드 입력을 없앴다(앱 저장소 docs/adr/0036). 교재는 구매한 수북 계정으로 앱에 로그인하면 등록된다.
--       넘길 수 있는 코드는 사고팔 수 있으므로, 화면에서 가리는 데 그치지 않고 DB에서도 구매자가 코드를 읽지 못하게 한다.
--       코드는 이제 구매와 앱 교재 권한을 잇는 안쪽 기록이다 — 주문마다 발급받는 흐름(대기열·트리거·service_role RPC)은 그대로다.
--
-- 하는 일:
--   1. get_my_order_app_access(주문 id) — 주문 회원 본인에게 앱 이용 상태만 준다(코드 없음).
--        state: waiting(로그인하면 등록됨) | registered(앱에 등록됨) | ended(환불로 끝남), app_download_url(끝난 주문은 null)
--        본인 주문이 아니거나 앱 패키지 주문이 아니면 null.
--   2. 코드 원문을 돌려주던 구매자 RPC를 없앤다: get_my_order_app_codes, get_guest_order_app_codes, _ilseong_app_buyer_lines.
--        비회원용은 대체 없이 없앤다 — 일성월심 학습지는 회원만 살 수 있다(20261116194737).
--   3. order_app_codes 표를 회원이 직접 읽던 정책·권한을 거둔다(이제 service_role만 읽는다).
--   4. notification_logs.notification_type 허용 목록에 app_guide(일성월심 앱 이용 안내)를 넣는다.
--        예전 app_code는 목록에 들어간 적이 없어 발송 기록이 남지 않았다(운영 DB에 app_code 기록 0건, 2026-11-18 확인).
--
-- 적용 시점의 운영 상태(2026-11-18): 앱 패키지 상품 0, order_app_codes 0줄, 판매 꺼짐 — 영향받는 주문 없음.
-- 화면: public-web 주문 상세는 get_my_order_app_access만 부른다. 이 migration보다 먼저 떠 있던 화면은
--       없어진 RPC를 부르지만 오류를 삼키고 아무것도 그리지 않는다(앱 패키지 주문이 없어 원래도 그릴 것이 없다).
-- 롤백: 20261109144159의 9절(구매자 RPC)과 3절의 select 정책·권한을 다시 실행하고, get_my_order_app_access를 지운다.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 구매자 화면용: 주문의 앱 이용 상태(코드 없음)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_my_order_app_access(p_order_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_total integer;
  v_active integer;
  v_registered integer;
begin
  if v_uid is null then
    return null;
  end if;
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.user_id = v_uid) then
    return null;
  end if;

  -- 끝난 줄: 앱 서버에서 폐기됐거나, 환불로 폐기를 요청한 줄.
  -- 단 환불 정책이 '이미 등록한 앱 이용은 유지'(revoke_access=false)이고 이미 등록한 줄은 계속 쓴다.
  select count(*),
         count(*) filter (where not x.ended),
         count(*) filter (where not x.ended and x.status = 'redeemed')
    into v_total, v_active, v_registered
  from (
    select c.status,
           (c.status = 'revoked'
            or (c.revoke_requested_at is not null
                and (coalesce(c.revoke_access, true) or c.status <> 'redeemed'))) as ended
    from public.order_app_codes c
    where c.order_id = p_order_id
  ) x;

  if v_total = 0 then
    return null;
  end if;

  return jsonb_build_object(
    'state', case
      when v_active = 0 then 'ended'
      when v_registered > 0 then 'registered'
      else 'waiting'
    end,
    'app_download_url', case
      when v_active = 0 then null
      else (select s.app_download_url from public.ilseong_app_settings s where s.id = 1)
    end
  );
end;
$$;

comment on function public.get_my_order_app_access(bigint) is
  '일성월심 앱 패키지 주문의 앱 이용 상태(주문 회원 본인만). 앱 코드는 돌려주지 않는다.';

revoke all on function public.get_my_order_app_access(bigint) from public, anon;
grant execute on function public.get_my_order_app_access(bigint) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 코드 원문을 돌려주던 구매자 RPC 제거
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.get_my_order_app_codes(bigint);
drop function if exists public.get_guest_order_app_codes(text, text);
drop function if exists public._ilseong_app_buyer_lines(bigint);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. order_app_codes 직접 읽기 회수 — 이제 service_role만 읽는다
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists order_app_codes_select_own on public.order_app_codes;
revoke all on table public.order_app_codes from anon, authenticated;

comment on table public.order_app_codes is
  '일성월심 앱 코드(주문 줄별). 구매와 앱 교재 권한을 잇는 안쪽 기록 — code는 service_role만 읽는다. 구매자에게는 get_my_order_app_access가 상태만 준다.';

comment on column public.ilseong_app_settings.app_download_url is
  '구매자 주문 상세 안내 칸의 "앱 받는 곳" 주소(https). 알림톡에는 넣지 않는다(카카오 심사: 앱 설치 유도 문구 불가).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 알림 기록: app_guide(일성월심 앱 이용 안내) 허용
--    기존 10종은 20260710032216과 같다(drop 후 같은 migration 안에서 다시 만든다).
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.notification_logs
  drop constraint if exists notification_logs_notification_type_check;

alter table public.notification_logs
  add constraint notification_logs_notification_type_check
  check (notification_type in (
    'pickup_accepted',    -- 수거접수 완료 (셀러)
    'arrived',            -- 입고 완료 (셀러)
    'inspection_done',    -- 검수 완료 (셀러)
    'sold',               -- 판매 완료 (셀러)
    'settlement_done',    -- 정산 완료 (셀러)
    'order_confirmed',    -- 주문 확인 (구매자)
    'shipping_started',   -- 배송 시작 (구매자)
    'delivery_done',      -- 배송 완료 (구매자)
    'restock',            -- 재입고 알림 (구매자)
    'refund_completed',   -- 환불 완료 (구매자)
    'app_guide'           -- 일성월심 앱 이용 안내 (구매자)
  ));

commit;
