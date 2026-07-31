-- pg_cron 활성화 + 미결제 자동취소 15분 스케줄 복구
--
-- 배경(2026-08-01): 카드결제 주문이 결제창 이탈 후 하루 가까이 pending(입금대기)으로
--   방치된 건을 진단하다 prod에 pg_cron 확장이 아예 설치돼 있지 않음을 발견.
--   2026051801의 스케줄 블록은 `if to_regnamespace('cron') is not null` 조건부라
--   확장이 없으면 에러 없이 조용히 no-op — 15분 만료 루프는 처음부터 존재한 적이 없다.
--   그동안 expire_unpaid_orders()는 admin-web Vercel 데일리 크론(0 18 * * * UTC,
--   Hobby 1회/일)만 호출해 와서, 카드 pending 30분 만료 룰(20260728121625)이
--   명목상만 존재했다(실제 방치 시간 최대 ~24h).
--
-- 변경 (비파괴):
--   1) pg_cron 설치 — 공식 문서 https://supabase.com/docs/guides/cron/install 의 SQL 그대로
--      (with schema pg_catalog + cron 스키마 grant 2종).
--   2) subook-expire-unpaid-orders 잡 (재)등록 — 2026051801과 동일한 잡 이름·주기(*/15).
--      unschedule 후 schedule이라 재실행에도 멱등.
--
-- 효과: 카드 pending 30~45분 내 자동취소(재고 선점 해제), 무통장 24h 만료·21~24h
--   입금 리마인더가 15분 정밀도로 실제 동작 시작. Vercel 데일리 크론은 백스톱으로 유지.

begin;

create extension if not exists pg_cron with schema pg_catalog;

grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

do $$
begin
  begin
    perform cron.unschedule('subook-expire-unpaid-orders');
  exception when others then
    null;
  end;

  perform cron.schedule(
    'subook-expire-unpaid-orders',
    '*/15 * * * *',
    $job$ select public.expire_unpaid_orders(); $job$
  );
end $$;

commit;
