# 성과 대시보드 연동·집계 기준

2026-09-12 개발. UI: `/admin/performance` (기존 `/admin/analytics`는 유지).

## 화면

- 기본 오늘 포함 최근 7일, 오늘·30일·이번 달 및 직접 날짜 선택(최대 366일).
- 모든 기간은 한국시간. 직전 동일 길이 기간과 비교하며 비율은 %p 차이로 표시한다.
- 매출·순매출·주문수·판매수량·AOV·구매자수, 방문자·구매전환율·조회→담기율·결제 이탈률, Meta CPA·ROAS.
- 일별 추이·상세 표, 날짜 선택으로 해당 일 전체 지표 조회.
- Meta 캠페인 → 광고세트 → 광고 상세. 총 광고 KPI는 상세 필터와 무관하게 전체 계정 기준을 유지한다.
- 연결되지 않은 지표, 실패한 조회, 0인 분모를 `—`로 표시한다. 정상적으로 조회한 빈 날짜의 건수·금액만 0으로 채운다.

## DB 계약

`admin_performance_report(p_from date, p_to date)`는 읽기 전용 SECURITY DEFINER 함수다. `is_admin_user()`를 검사하고 anon/PUBLIC 실행 권한을 회수한다. 인증 사용자의 실행 권한도 함수 내부 관리자 검사에 종속된다. 기존 RLS·결제·주문·환불 함수는 변경하지 않는다.

| 지표 | 계산 |
|---|---|
| 기준 주문 | payment_status=paid/refunded이며 paid_at 또는 pg_approved_at로 결제가 확인된 주문 |
| 기준 날짜 | coalesce(paid_at, pg_approved_at)의 Asia/Seoul 날짜 |
| 매출 | 할인·포인트 적용 후 total_amount 합계. 배송비 포함, 환불 전 실결제액 |
| 환불 | refunded_amount 누계. payment_status=refunded인 전액환불은 total_amount로 보완 |
| 순매출 | 해당 기간 결제액 − 해당 주문들의 현재 누적 환불액 |
| 주문수 | 결제 이력이 있는 주문 ID 수. 환불 주문도 포함 |
| 판매수량 | order_items.quantity 합계 − 환불 품목 수량. 주문과 상품을 먼저 별도로 집계해 매출 중복 방지 |
| AOV | 환불 전 매출 ÷ 결제 주문수. 주문 없으면 null |
| 구매자 | 회원 user_id, 비회원 정규화된 주문 연락처로 각각 중복 제거. 연락처가 없으면 주문별 집계 |
| 확인된 Meta 유입 | last_touch의 Meta 계열 source와 paid 계열 medium이 모두 존재하는 결제분. 순매출 기준, 전액환불 구매 제외 |

이 순매출은 **결제 기간 코호트 기준**이다. 당일 발생한 환불 전체를 당일 매출에서 빼는 현금흐름 지표가 아니다. 나중에 환불하면 과거 기간 순매출이 달라진다. 동일인이 회원·비회원으로 구매하면 구매자수가 중복될 수 있다. 결제 시각 없는 과거 기록은 제외 건수를 표시한다. 결제 이력이 있으나 취소 상태인 기록은 결제·환불 원장대로 포함하고 확인 건수를 표시한다.

## GA4 연결

서버 환경 변수:

| 이름 | 값 또는 보관할 내용 |
|---|---|
| GA4_PROPERTY_ID | `547066648` |
| GA4_WIF_AUDIENCE | `//iam.googleapis.com/projects/695300920550/locations/global/workloadIdentityPools/subook-admin-performance/providers/vercel` |
| GA4_SERVICE_ACCOUNT_EMAIL | `subook-performance-reader@subook-nano.iam.gserviceaccount.com` |

2026-09-12 사용자 승인 후 서비스 계정을 생성하고 **이 GA4 속성의 Viewer**로 추가했다. Google Analytics Data API와 IAM Service Account Credentials API를 활성화했다. 조직의 `iam.disableServiceAccountKeyCreation` 정책을 유지하며 JSON 키 대신 Vercel OIDC와 Google Workload Identity Federation을 사용한다. 위 세 설정값은 Vercel production에 등록했다.

- issuer: `https://oidc.vercel.com/seongwoooooks-projects`, audience: `https://vercel.com/seongwoooooks-projects`.
- Google provider는 Vercel 팀 `team_NJYefxoT5xHMSnAX9Z0Uakwu`, 프로젝트 `prj_pWxo8Nq6uwPBlOGkj1hlcS7DIe4V`, `production` 환경으로 제한한다.
- `google.subject=assertion.sub`. 서비스 계정 가장 권한은 `owner:seongwoooooks-projects:project:subook-admin-web:environment:production` 주체에만 부여한다. Cloud 리소스 조회·관리 역할은 추가하지 않는다.
- `@vercel/oidc`로 실행 환경의 토큰을 얻어 Google STS에서 교환한 후, 서비스 계정의 `analytics.readonly` 토큰을 15분간 발급받는다. 토큰과 개인 gcloud 인증정보는 저장하지 않는다.
- 기존 JSON 연결 방식(`GA4_SERVICE_ACCOUNT_JSON`)도 코드에서 지원하지만 운영 환경에는 등록하지 않았다. WIF 설정이 있으면 WIF를 우선한다.

- Core: Data API v1beta `batchRunReports`, totalUsers / sessions / ecommercePurchases / sessionKeyEventRate:purchase.
- 기간 방문자는 별도 기간 보고서로 중복 제거한다. 일별 방문자를 합산하지 않는다.
- 두 개의 독립된 닫힌 2단계 사용자 퍼널: view_item→add_to_cart, begin_checkout→purchase.
- 퍼널은 Data API **v1alpha** `runFunnelReport`를 사용한다. 순서 있는 사용자 코호트이며 세션을 넘는 후속 행동도 포함할 수 있다. 바로구매는 두 번째 퍼널에 포함된다. 퍼널 실패 시 core 방문 데이터를 유지하고 퍼널만 조회 실패로 표시한다.
- GA4 무통장 purchase는 주문 생성 시점(입금 전)이다. 결제 이탈률을 실결제 실패율로 해석하면 안 된다.
- 서울 시간대를 확인하고 다르면 표시하지 않는다. 기준점·표본 적용 상태도 화면에 알린다.

근거: [GA4 서비스 계정 연결](https://developers.google.com/analytics/devguides/reporting/data/v1/quickstart-client-libraries), [지표 명세](https://developers.google.com/analytics/devguides/reporting/data/v1/api-schema), [배치 보고서](https://developers.google.com/analytics/devguides/reporting/data/v1/rest/v1beta/properties/batchRunReports), [퍼널 명세·v1alpha 제한](https://developers.google.com/analytics/devguides/reporting/data/v1/funnels), [서비스 계정 OAuth](https://developers.google.com/identity/protocols/oauth2/service-account).

키 없는 인증 근거: [Vercel–GCP OIDC](https://vercel.com/docs/oidc/gcp), [Vercel 토큰 주체](https://vercel.com/docs/oidc/reference), [Google STS](https://docs.cloud.google.com/iam/docs/reference/sts/rest/v1/TopLevel/token), [서비스 계정 단기 토큰](https://docs.cloud.google.com/iam/docs/reference/credentials/rest/v1/projects.serviceAccounts/generateAccessToken).

## Meta 연결

| 이름 | 값 또는 보관할 내용 |
|---|---|
| META_AD_ACCOUNT_ID | `1507168001446517` (`act_` 접두사도 허용) |
| META_ADS_ACCESS_TOKEN | 해당 광고 계정 조회 권한과 `ads_read`를 가진 토큰. Vercel 비밀 환경 변수로 보관 |
| META_GRAPH_API_VERSION | 선택 사항. 기본 `v26.0` |

2026-09-12 공식 광고 관리자에서 현재 집행 중인 `9/9 수북X전일 캠페인`이 **수북 subook / 1507168001446517** 계정에 있음을 확인했다. 초기 조사·승인 질문의 `1667285971026064`는 이전 계정이므로 현재 집행 계정으로 정정했으며 사용자에게 설명했다. 화면에 연결된 계정명과 ID를 표시한다.

비즈니스 `3645023768984708`에 `수북 성과 대시보드` 앱(`4553544514967620`)과 Employee 시스템 사용자 `SubookReader`(`61593967875660`)를 생성했다. 현재 광고 계정에는 **성과 보기**, 조회 앱에는 **앱 테스트**만 할당했다. 토큰 발급 선택은 만료 없음·`ads_read`만이다. Meta의 추가 이메일 인증 후 발급·실제 조회 검증을 이어서 진행한다.

기존 Vault의 `meta_capi_access_token`은 전환 이벤트 전송 목적으로 보관된 토큰이다. 광고 조회 권한이 있다는 가정으로 재사용하지 않는다. 광고 생성/수정 권한을 요청하지 않는다.

- 계정 통화 KRW·시간대 Asia/Seoul을 확인한 후 조회한다. 다른 통화를 원으로 표시하지 않는다.
- Insights의 spend / impressions / clicks / actions / action_values를 조회한다.
- `action_report_time=conversion`, `use_unified_attribution_setting=true`로 광고세트 기여 설정을 적용한다. 광고 관리자 기본 보고일/기여 설정과 다르면 UI 수치도 다를 수 있다.
- 구매 action_type은 purchase → omni_purchase → offsite_conversion.fb_pixel_purchase 순으로 **하나만** 선택한다. 중복 표현을 합산하지 않는다.
- CPA=광고비/기여 구매수, ROAS=기여 매출/광고비×100. 기간 합계로 재계산한다.
- 모든 페이지를 커서로 조회하고, 외부 `paging.next` URL은 직접 따라가지 않는다. 페이지 한도를 넘기면 부분 합계를 완전한 결과로 표시하지 않는다.
- 출처가 기록된 DB Meta 실적은 별도 참고값이다. 보존 시작일 2026-09-12 이전 주문을 소급 복원하지 않으며 전체 광고 매출이라고 표시하지 않는다.
- DB 유입은 여러 Meta 계정에서 올 수 있어 단일 광고 계정의 광고비로 나눈 DB ROAS를 제공하지 않는다.

근거: [Meta 공식 API 컬렉션](https://www.postman.com/meta/facebook-marketing-api/overview), [Meta 광고 Insights 예제](https://www.postman.com/meta/facebook-marketing-api/request/u07tack/get-ad-insights-l1), [공식 SDK Insights 필드](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/adsinsights.py), [공식 SDK 계정 Insights 매개변수](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/adaccount.py), [공식 SDK v26.0](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/apiconfig.py).

## 동작과 배포

`api/admin/performance.js`가 매 요청의 관리자 인증을 확인한 뒤 외부 API를 조회한다. 응답은 `private, no-store`. 서버 인스턴스 내부에서 최대 15분/32개 결과 캐시와 동일 요청 합치기를 사용한다. 서버 재시작 시 사라지는 캐시이며 별도 스케줄러나 데이터 적재 테이블은 없다. 새로고침은 DB를 다시 읽고 외부 지표는 유효한 캐시를 사용할 수 있다. 외부 1회 요청 12초, 일시 오류만 1회 재시도, 출처별 전체 40초 제한이다.

Backend 원본 `api/admin/performance.js`, `api/_lib/performance.js`를 frontend `apps/admin-web/api/`의 동일 경로에 동기화한다. 서버 의존성 `@vercel/oidc` 3.8.7은 양쪽 package.json과 admin `vercel.root-package.json`에 포함한다. 모든 인증정보는 서버 전용이며 `VITE_` 이름으로 저장하지 않는다. 클라이언트는 shared-supabase 경유 RPC와 인증된 admin API만 호출한다.

배포 루트가 CommonJS이므로 헬퍼도 `.js`로 두어 Vercel 빌더가 함께 컴파일하도록 한다. `.mjs` 정적 import는 로컬 Node 24에서 작동해도 Vercel 런타임의 require 후킹에서 `ERR_REQUIRE_ESM`이 발생한다. 루트의 모듈 설정을 변경해 다른 API의 실행 방식을 바꾸지 않는다.

2026-09-12 사용자가 **“조회 연동 설정과 배포까지 진행”**을 승인했다. GA4 설정 등록과 대시보드 집계 migration 운영 반영을 완료했다. Meta 조회 토큰 연결과 실제 운영 API 검증·배포를 이어서 진행한다.

기본 작업 폴더의 dry-run에는 기존 미추적 파일 `20260905031459_fix_create_order_reserved_check_ignore_refunded_items.sql`이 함께 잡혔다. 이 결제 수정은 이번 작업에 포함하지 않는다. 추적 중인 migration과 새 `20260912093504_admin_performance_report.sql`만 복사한 독립 workdir에서 dry-run을 수행해 **새 대시보드 함수 1개만 적용 대상으로 표시되는 것**을 확인하고 push했다. migration list의 local/remote 일치를 확인했다. 무관한 파일을 포함하려고 `--include-all`을 사용하지 않는다.

승인 후: 조회 계정/토큰 준비 → Vercel production에 비밀 변수 추가 → 새 migration만 dry-run 확인 후 push → 실제 GA4/Meta 결과와 콘솔 대조 → 각 repo 검증/commit/push → 루트 `npm run deploy:admin` → READY/production 확인. 사용자용 앱 변경은 없으므로 public 배포는 필요 없다.

## 검증

- `node --test backend/api/admin/performance.test.js frontend/packages/shared-domain/src/performanceMetrics.test.js`
- SQL: `tests/performance_dashboard.sql`의 주입 지점에 migration 본문(begin/commit 제외, 함수의 public 참조를 performance_test로 변경)을 삽입한 후 **전체 트랜잭션을 rollback**한다. 전용 테스트 스키마만 사용하고 운영 주문/트리거에 쓰지 않는다.
- 전체 frontend lint, admin 변경 파일 별도 lint, admin/public build, 기존 public test 215개.
- 로컬 브라우저에서 현재 운영 DB의 임시 함수 집계를 읽어 기본 7일·오늘·커스텀 기간·일별 표를 검증한 뒤 임시 함수는 rollback했다. 승인 후 정식 migration만 별도로 반영했다.
- 외부 실제 계정은 연결 전이므로 API 호출은 응답 fixture로 검증. 브라우저 fixture는 명시적으로 예시 데이터임을 표시하고 배포에 포함하지 않는다.
- 결과: 새 JS 테스트 16개·SQL assertion 전체·기존 public 테스트 215개·lint·양 앱 build 통과. 390px 브라우저에서 가로 넘침 없음, 개발 페이지 JS 오류 없음. 실제 외부 API 계정 연동과 운영 배포 확인은 이어서 수행한다.
