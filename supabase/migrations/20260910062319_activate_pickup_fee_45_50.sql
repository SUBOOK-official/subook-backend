-- public/admin/seller의 신규 정책 UI가 production READY인 것을 확인한 뒤 적용한다.
-- 실제 적용 시점은 배포 완료 단계에서 DB 시계로 기록하며 기존 수거/정산은 갱신하지 않는다.
begin;
insert into public.pickup_fee_policy_releases(version, activated_at)
values ('2026-09', clock_timestamp())
on conflict (version) do nothing;
commit;

-- 롤백 시 활성화 행/기존 스냅샷을 삭제하지 않는다. 이미 동의한 수거의 요율을 유지하고
-- 새 정책 중단이 필요하면 후속 migration에서 신규 접수 정책만 별도로 조정한다.
