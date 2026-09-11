# Meta 결제 완료 Purchase 운영

2026-09-11 구현. 데이터 세트 `27962792746720705`, 비즈니스 `3645023768984708`.

현재: **2026-09-11 12:33 KST 운영 전환 완료.** Meta 본인 확인 및 비즈니스 프로필 이메일 인증을 마쳤고,
Vault `meta_capi_access_token` 등록, 서버 전송 `enabled=true`, 매분 크론 성공을 확인했다.
frontend `a9fd41b`를 main으로 통합·push한 뒤 배포했다.
배포 `dpl_37zib4nnjpvgTjpZp1FFWxDr2y74`: **READY / production**, `https://subook.kr` 반영.

연결 검증은 실제 `/store/2371` 조회의 상품 ID·발생 시각·기존 브라우저 event_id를 유지한
ViewContent를 운영 `meta_purchase_http` 함수로 전송해 **HTTP 200 / events_received=1**로 확인했다.
가짜 Purchase·테스트 주문·과거 구매 전송은 하지 않았다. 새 실제 결제의 outbox confirmed 확인은 아직 남아 있다.

## 전송 기준

- **무통장: 운영자가 입금 확인. 카드: 서버 승인 완료.** 기존 `orders.payment_status=paid`와 `paid_at`을 사용한다. 결제·환불·정산 RPC 자체는 수정하지 않는다.
- 새 public-web 체크아웃이 `attach_meta_checkout_context`로 등록한 주문만 전송한다. 배포 전 주문을 소급 집계하지 않는다.
- Meta Purchase는 서버가 담당하고 브라우저의 동일 이벤트는 제거한다. 기존 Meta 지원 게이트웨이는 조회·장바구니 등 다른 이벤트를 계속 처리한다.
- GA4 purchase는 기존 기준을 유지한다. 무통장 주문 생성 기준의 GA4 구매 수와 Meta 결제 완료 구매 수를 그대로 비교하지 않는다.
- 1분 주기로 최대 5건 전송한다. 실제 발생 시각은 전송 시각이 아니라 `paid_at`이다. Meta 화면 반영에는 추가 지연이 있을 수 있다.
- `event_id`는 주문 번호의 SHA-256 기반이며 재시도·중복 트리거에서도 동일하다. 성공 판정은 HTTP 200과 `events_received=1` 모두 충족해야 한다.
- value는 배송비·쿠폰·포인트 등을 반영한 주문의 `total_amount`이며 KRW. 콘텐츠 ID는 전일 3종 예외 매핑 후 그 외 `products.id` 문자열이다. 매핑을 바꿀 때 frontend `packages/shared-domain/src/metaCatalog.js`와 함께 검토한다.

## 전환 순서 — 필수

1. migration `20260910191535_meta_purchase_tracking.sql`을 적용한다. 기본 `enabled=false`이며 기존 주문 데이터는 변경하지 않는다.
2. Meta 이벤트 관리자 → subook 데이터 → 설정 → 전환 API → 직접 통합 → **Dataset Quality API 없이 설정** → 액세스 토큰 만들기. 비즈니스 프로필 이메일이 없으면 이메일 등록·인증부터 해야 한다. 계정 본인 확인은 계정 소유자가 수행한다.
3. 발급값을 Supabase Vault의 `meta_capi_access_token`에 저장한다. 토큰은 브라우저 소스, VITE 변수, Git, 명령줄, 로그, 이 문서에 넣지 않는다. 기존 게이트웨이를 삭제하거나 토큰 권한을 불필요하게 넓히지 않는다.
4. 토큰과 서버 HTTP 연결을 검증한 후 `meta_tracking_config.enabled=true`로 전송을 켠다. 아직 새 체크아웃 문맥이 없으면 전송 대상은 없다.
5. 새 public-web을 배포한다. **2~4가 완료되지 않은 상태에서 브라우저 Purchase를 제거한 버전을 먼저 배포하면 안 된다.**
6. 신규 실제 결제 후 outbox의 `confirmed`와 이벤트 관리자 → 개요 → 구매 및 이벤트 테스트/활동을 확인한다. 가짜 결제나 과거 구매를 전송해 상태를 녹색으로 만들지 않는다.

토큰 검증 전의 설치 완료는 전체 추적 전환 완료가 아니다. 배포 당시 작업 기록과 실제 `enabled` 값을 함께 확인한다.

## 개인정보와 권한

- 문맥 RPC는 운영 출처 `https://subook.kr`, 새 주문/카드 세션(30분 이내), 회원 소유권 또는 비회원 주문 번호+전화번호를 확인한다. Origin은 추가 필터일 뿐 인증 수단이 아니다.
- DB가 접속 IP·사용자 에이전트를 요청 헤더에서 읽고 실제 `_fbp`/`_fbc` 쿠키만 저장한다. 광고 클릭 쿠키가 없으면 임의로 만들지 않는다.
- 서버 연락처 매칭은 마케팅에 동의했고 탈퇴·차단 상태가 아닌 회원의 이메일·전화번호 SHA-256 해시만 사용한다. 비회원의 수령인 연락처, 배송 주소, 원문 연락처, 결제수단 정보는 전송하지 않는다. 해시는 익명정보가 아니다.
- 새 테이블은 RLS와 권한 제한으로 일반 사용자 접근을 차단한다. 전송·큐 함수는 서버만 실행한다.
- 토큰을 pg_net 공용 요청 큐에 저장하지 않는다. 별도 pg_cron worker가 http 확장으로 Meta 고정 주소에 직접 전송하며, 결제 트랜잭션은 HTTP를 기다리지 않는다.
- 성공 payload는 즉시 제거한다. 문맥/남은 payload는 최대 7일, 시도 제한 키는 1일, 전송 메타데이터는 90일 후 정리한다. GPC 브라우저에서는 픽셀과 새 문맥 등록을 실행하지 않는다.

## 점검 SQL — 관리자 전용, 원문 payload 조회 불필요

```sql
select enabled, installed_at from public.meta_tracking_config;
select status, count(*), min(event_time) as oldest_event,
       max(confirmed_at) as latest_success
from public.meta_purchase_outbox group by status;
select order_id, event_time, attempts, last_http_status, last_error
from public.meta_purchase_outbox
where status='failed' or (status='pending' and event_time < now()-interval '15 minutes')
order by event_time;
select count(*) as paid_context_without_queue
from public.orders o join public.meta_checkout_contexts c using(order_number)
left join public.meta_purchase_outbox q on q.order_id=o.id
where o.payment_status in ('paid','refunded') and o.paid_at is not null and q.order_id is null;
select d.status,d.start_time,d.end_time
from cron.job_run_details d join cron.job j using(jobid)
where j.jobname='subook-meta-purchase-sweep' order by d.runid desc limit 10;
```

- `pending`이 짧게 존재하는 것은 정상이다. 15분 이상 적체되면 스위치·Vault 등록 여부·크론 실행·오류 코드를 확인한다. 전체 결제 수와 비교할 때는 **새 버전 체크아웃 및 같은 시간대**로 한정한다.
- 브라우저 문맥 저장은 요청당 1.5초, 최대 2회이며 실패해도 결제는 진행한다. 실패하면 GA4 exception `meta_checkout_context_unavailable`이 기록된다. 따라서 실제 모든 결제의 100% 수집을 보장하지 않는다.
- HTTP 429/5xx/일시 오류는 동일 ID로 재시도한다. 영구 오류는 failed. 최대 12회 또는 결제 시각부터 36시간 후 자동 중단한다. 토큰 오류는 `graph_190` 등 코드만 남긴다.
- Meta는 동일 이벤트 이름+ID를 이용해 중복을 제거한다. 오래된 failed를 무조건 재전송하면 안 된다. 원인을 고친 뒤 수신 여부·발생 시간·중복 제거 기간을 검토해 수동 복구한다.
- 서버 전용 Purchase로 전환하면 ‘픽셀 대비 전환 API 커버율’이나 브라우저/서버 중복 제거 비율이 이전과 달라질 수 있다. 이것을 곧바로 누락으로 판단하지 말고 실제 새 결제와 outbox 수신 결과를 대조한다.

## 중단·롤백

`update public.meta_tracking_config set enabled=false where singleton;`으로 서버 전송을 중단할 수 있다. 이 동안 큐 적재는 유지되며 재시도 기간을 넘긴 주문은 failed가 된다.

브라우저 Purchase를 다시 켤 때는 서버 중단과 배포 시각을 기록하고, 이미 서버가 보낸 주문을 브라우저가 다시 보내지 않도록 별도 검토한다. 테이블·주문을 삭제해서 롤백하지 않는다. 기존 브라우저 버전으로 돌아가면 무통장 입금 전 집계 문제도 돌아온다.

## 검증과 근거

- `tests/meta_purchase_tracking.sql`은 **BEGIN/ROLLBACK 트랜잭션 내에서만** 실행한다. HTTP 함수를 테스트 대역으로 바꾸므로 실제 Meta 이벤트를 보내지 않는다. 전일 상품 2370과 동의/미동의 회원 fixture가 있는 DB가 필요하다. 기존 회원은 읽기만 하며 합성 주문·토큰·함수 변경은 모두 롤백한다.
- 권한, 입금 전 제외, 회원/비회원 소유권, 개발·과거 주문 제외, 카드 세션, 결제 후 문맥 복구, 동의별 해시, 동일 ID, 일시/영구 오류, 성공 payload 제거를 검증했다.
- 최종 frontend 테스트208개·lint·public/admin build 통과. 운영 상품 → 비회원 주문서 진입, 카드/무통장 선택 화면과 콘솔 error 0을 확인했으며 주문 제출은 하지 않았다.
- CAPI 토큰으로 픽셀 관리 정보 GET 조회는 Graph 100으로 실패했지만, 동일 데이터 세트의 실제 이벤트 POST는 성공했다. 관리 정보 조회 실패만으로 전송 토큰이 무효라고 단정하거나 권한을 넓히지 않는다. 토큰 검증용 실제 조회의 같은 event_id를 재사용했으며 새 Purchase를 만들어 검증하지 않았다.
- 토큰은 로컬 일회용 등록 폼에서 TLS 인증서를 검증한 DB 연결과 SQL 매개변수로 Vault에 저장했다. DB 매개변수 로깅을 해당 트랜잭션에서 차단했고 비밀값을 파일·터미널·Git에 남기지 않았다. 등록 서버와 임시 브라우저 창은 종료했다.
- [Meta 전환 API 사용](https://developers.facebook.com/documentation/ads-commerce/conversions-api/using-the-api/) — v26.0, 실제 event_time, events_received, 동일 ID 재시도. 테스트 코드가 붙은 이벤트도 측정에 영향을 줄 수 있으므로 가짜 Purchase를 보내지 않는다.
- [Meta 고객 매개변수](https://developers.facebook.com/documentation/ads-commerce/conversions-api/parameters/customer-information-parameters) — 이메일·전화번호 정규화/해시 및 쿠키·IP·UA 규칙.
- [Supabase HTTP](https://supabase.com/docs/guides/database/extensions/http), [HTTP 확장 헤더/타임아웃](https://github.com/pramsey/pgsql-http), [Supabase Vault](https://supabase.com/docs/guides/database/vault).
