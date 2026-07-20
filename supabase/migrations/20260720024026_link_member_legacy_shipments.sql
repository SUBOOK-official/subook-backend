-- ─────────────────────────────────────────────────────────────────────────────
-- 구사이트(비회원 입고) 판매 건 ↔ 회원 자동 연결
--
-- 배경: 마이페이지 판매현황 RPC(get_member_dashboard_summary 등)는
-- shipments.user_id = auth.uid() 기준인데, 리뉴얼 전 입고된 shipments
-- (2026-07-20 기준 24건, 책 1,000권: on_sale 600 · settled 400)는 user_id가
-- 전부 null이라 해당 셀러가 신규 사이트에 가입해도 판매 현황이 안 보인다.
--
-- 2026040705_member_management의 일회성 백필과 동일 규칙을
--   ① 트리거로 상시화 (가입 시·이름/전화 변경 시 자동 연결)
--   ② 현재 회원 대상 일회성 소급 백필
-- 규칙: 이름 일치 + 전화 숫자만 일치 + 동일 매칭 회원이 유일할 때만.
--       (모호하면 연결하지 않음 — 타인 판매현황 노출 방지)
-- user_id가 이미 있는 shipment는 절대 변경하지 않는다.
--
-- 신규 회원 수거신청 → 검수 전환은 admin_start_inspection_from_pickup이
-- pickup_requests.user_id를 직접 복사하므로 이 트리거와 무관하게 정상.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._link_member_legacy_shipments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.phone is null or btrim(new.phone) = '' then
    return new;
  end if;
  if new.name is null or btrim(new.name) = '' then
    return new;
  end if;

  update public.shipments s
  set user_id = new.user_id
  where s.user_id is null
    and s.seller_name = new.name
    and regexp_replace(s.seller_phone, '[^0-9]', '', 'g') =
        regexp_replace(new.phone, '[^0-9]', '', 'g')
    and not exists (
      select 1
      from public.member_profiles mp2
      where mp2.name = s.seller_name
        and regexp_replace(coalesce(mp2.phone, ''), '[^0-9]', '', 'g') =
            regexp_replace(s.seller_phone, '[^0-9]', '', 'g')
        and mp2.user_id <> new.user_id
    );

  return new;
end;
$$;

drop trigger if exists trg_link_member_legacy_shipments on public.member_profiles;
create trigger trg_link_member_legacy_shipments
  after insert or update of name, phone on public.member_profiles
  for each row execute function public._link_member_legacy_shipments();

-- ── 일회성 소급 백필 (2026040705 이후 가입자 대상, 동일 규칙) ──────────────────
update public.shipments s
set user_id = matched.user_id
from (
  select s2.id as shipment_id, mp.user_id
  from public.shipments s2
  join public.member_profiles mp
    on mp.name = s2.seller_name
   and regexp_replace(coalesce(mp.phone, ''), '[^0-9]', '', 'g') =
       regexp_replace(s2.seller_phone, '[^0-9]', '', 'g')
  where mp.phone is not null
    and not exists (
      select 1
      from public.member_profiles mp2
      where mp2.name = s2.seller_name
        and regexp_replace(coalesce(mp2.phone, ''), '[^0-9]', '', 'g') =
            regexp_replace(s2.seller_phone, '[^0-9]', '', 'g')
        and mp2.user_id <> mp.user_id
    )
) matched
where s.id = matched.shipment_id
  and s.user_id is null;
