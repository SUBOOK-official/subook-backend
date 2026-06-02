-- 직전 grant(confirm_member_purchase)를 PostgREST 스키마 캐시에 즉시 반영.
-- GRANT만으로는 PostgREST auto-reload가 항상 트리거되지 않아 권한 변경이 캐시에 안 잡힐 수 있다.
notify pgrst, 'reload schema';
