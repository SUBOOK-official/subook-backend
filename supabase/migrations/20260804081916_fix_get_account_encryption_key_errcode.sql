-- get_account_encryption_key 오류 경로 수리 (2026-08-04 plpgsql_check 전수 감사에서 발견)
--
-- 문제: 마지막 RAISE의 `using errcode = 'configuration_required'`에서
--   'configuration_required'는 유효한 PostgreSQL 예외 조건명/SQLSTATE가 아님.
--   키가 GUC/private.app_secrets 어디에도 없을 때 의도한 안내 메시지 대신
--   42704 "unrecognized exception condition"으로 실패해 장애 원인 파악을 방해.
-- 수리: errcode 절 제거 → 기본 P0001(raise_exception)로 발화. 본문 나머지는 동일.
--   이 조건명을 참조하는 예외 핸들러/프론트 코드 없음 확인 완료라 동작 계약 변경 없음.

create or replace function public.get_account_encryption_key()
returns text
language plpgsql
stable
security definer
set search_path = public, private
as $$
declare
  v_key text;
begin
  -- 1순위: GUC (운영자가 Supabase Dashboard에서 설정한 경우)
  v_key := coalesce(
    nullif(current_setting('app.account_encryption_key', true), ''),
    nullif(current_setting('app.settings.account_encryption_key', true), ''),
    nullif(current_setting('subook.account_encryption_key', true), '')
  );

  if v_key is not null then
    return v_key;
  end if;

  -- 2순위: private.app_secrets 테이블
  select value into v_key
    from private.app_secrets
   where key = 'account_encryption_key';

  if v_key is not null and length(v_key) > 0 then
    return v_key;
  end if;

  raise exception 'Account encryption key is not configured. Insert into private.app_secrets (key=''account_encryption_key'', value=''<strong-secret>'').';
end;
$$;
