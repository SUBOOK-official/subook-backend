-- 운영 실측: 대량 수식이 있는 원장에서는 20행 batch가 123.838초 소요.
-- Apps Script 6분 실행 한도 + HTTP 리다이렉트 여유 1분. 응답 유실 감지는 기존 10분.
-- https://developers.google.com/apps-script/guides/services/quotas
-- 롤백은 420000을 120000으로 복원한다. 데이터/권한/DB 설정 변경 없음.
begin;
do $$
declare v_old text;
begin
  v_old:=pg_get_functiondef('public.gsheet_sync_sweep()'::regprocedure);
  if position('timeout_milliseconds:=120000' in v_old)=0 then raise exception 'gsheet timeout changed; review'; end if;
  execute replace(v_old,'timeout_milliseconds:=120000','timeout_milliseconds:=420000');
end;
$$;
commit;
