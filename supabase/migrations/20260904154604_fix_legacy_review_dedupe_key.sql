-- 이미 적용된 20260904154012 함수는 pgcrypto digest를 찾을 수 있도록 extensions를 포함한다.
-- 신규 환경에서는 앞 migration이 기본 md5를 사용하지만 이 설정을 유지해도 동작은 동일하다.

begin;

alter function public.admin_import_legacy_review(text, bigint[], integer, text, timestamptz, integer)
  set search_path = public, extensions;

commit;

notify pgrst, 'reload schema';
