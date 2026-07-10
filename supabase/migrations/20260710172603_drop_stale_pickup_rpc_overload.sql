-- submit_pickup_request 구버전 오버로드 제거 (예방 정리)
--
-- 차단/해제 RPC 오버로드 버그(20260710172341)와 같은 패턴 전수 점검에서 발견:
-- 교재 개별등록 시절의 10인자 구버전이 20260608000000의 17인자 현행판과 공존.
-- 구버전 인자가 현행판의 부분집합이라 PostgREST로는 현재 도달 불가(모호성으로 거부)
-- 하지만, (1) 구버전엔 차단 가드(assert_member_not_blocked)가 없고
-- (2) 현행판 시그니처가 바뀌는 순간 구버전이 되살아나는 지뢰라 명시 제거한다.

drop function if exists public.submit_pickup_request(
  text, text, text, text, text, text, text, text, text, jsonb
);
