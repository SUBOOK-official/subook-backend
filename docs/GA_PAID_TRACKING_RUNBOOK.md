# 실결제 GA 계측·성장 실험 운영 (2026-09-29)

GA4 속성 `547066648`, 웹 스트림 `15321382805`, 측정 ID `G-EMNCLZKPMS`만 사용한다. 구 속성 `545131895`는 변경하지 않는다. 사용자에게 개인정보 고지·수집 처리 권한 확인 및 GA 연결 승인을 받았다.

## 구매 정의와 전송

- `purchase`는 실제 입금·카드 승인 완료 기준이다. 미입금 무통장 주문은 `order_created`로 분리한다. 9/29 전후 전환율과 매출은 정의가 달라 직접 비교하지 않는다.
- 실제 gtag `get`으로 읽은 client_id/session_id만 주문·PG 세션에 연결한다. 동의 거절·차단·GPC·개발/프리뷰·PG 심사 모드에는 식별자를 만들어 보완하지 않는다.
- 신규 주문부터 적용하며 과거 누락 16건을 소급 전송하지 않는다. 결제 트랜잭션에서는 큐만 적재하고 외부 통신·계측 예외가 결제를 막지 않도록 한다.
- 주문당 outbox 1행, transaction_id=order_number. 서버가 맡은 주문은 완료 페이지에서 중복 전송하지 않는다. 서버 연결이 없는 실제 결제는 브라우저에서 1회 보완한다.
- GA `value`는 할인 후 상품금액(총 결제액−배송비), shipping은 별도다. 품목은 안정적인 상품 ID·브랜드·과목을 포함하고 할인은 단가에 비례 배분한다. DB 성과 대시보드의 배송비 포함 실결제액과 구분한다.
- 이름·전화·이메일·주소·계좌·자유 입력은 GA로 보내지 않는다. 광고용 user_data와 personalization은 DENIED. 주문 소유권 확인용 게스트 전화는 저장/GA 전송하지 않는다.
- Vault의 `ga4_measurement_api_secret`만 사용한다. 키를 파일·환경 변수·클라이언트·로그에 복사하지 않는다.
- 분당 최대 5건, 일시 오류(0/429/5xx) 최대 8회 지수 재시도, 결제 후 48시간 한도. 성공/영구 실패 시 payload 제거. 문맥 7일·상태 90일 보관.
- HTTP 2xx는 `accepted`이며 **GA 보고서 처리 성공을 보장하지 않는다**. `transactionId`로 실결제 DB와 대조한다. GA 응답의 threshold/dataLoss/10,000행 제한이 있으면 대조값을 미집계로 표시한다.

## 상태 확인과 비활성화

```sql
select enabled, installed_at from public.ga_tracking_config;
select status,count(*),min(event_time),max(last_http_status)
from public.ga_purchase_outbox group by status;
select j.jobname,d.status,d.end_time
from cron.job j left join lateral (
  select status,end_time from cron.job_run_details where jobid=j.jobid order by start_time desc limit 1
) d on true where j.jobname='subook-ga-purchase-sweep';
```

키 검증 후에만 `update public.ga_tracking_config set enabled=true where singleton;`로 활성화한다. 긴급 중단은 false로 전환하며 큐/주문은 보존한다. 중단 전에 서버가 맡은 주문은 브라우저 보완으로 자동 전환하지 않으므로 복구 후 48시간 안에 재처리한다. 이미 accepted인 주문을 일괄 재전송하지 않는다. 기존 운영 크론 경보에 새 잡(15분 임계)을 추가했다.

## 전환·안내 실험

- 주요 이벤트: `purchase`, `pickup_request_complete`만. `view_item`, `view_cart`, `view_promotion`은 탐색 지표다. 수거 완료는 기존 `generate_lead`의 `lead_type=pickup_request` 성공 시점에 별도 이벤트로 발화한다.
- `guest_checkout_guide_v1`, `pickup_preparation_v1`: 브라우저에 control/guide를 50:50 고정. 저장 불가 시 편입하지 않는다. 노출=`experiment_exposure`, 이후 행동에 같은 실험 파라미터를 포함한다.
- 주문 실험은 노출→입력검증→실결제, 수거 실험은 노출→각 단계→신청 완료로 본다. 14일 이상 관측하고 각 군 분모·실제 전환·기간/채널 차이를 함께 보고 유의하지 않으면 우열을 확정하지 않는다. 실험 기간 중 문구/배정 알고리즘을 바꾸면 버전을 올린다.
- 검색 복구=`search_recovery`, 품절 대안=`soldout_alternative_click`. 같은 검색어라도 필터 변화는 별도 검색으로 계측한다.
- 정상 미출시 전일 상품은 `jeonil_product_unavailable`로 분류한다. 후기 조회에는 unmount 후 응답 방지와 제한된 실패 사유만 추가했으며 네트워크 장애 원인 해결을 주장하지 않는다.

## 관리자 도구

`/admin/performance`에 실결제/GA 주문번호 대조·실제 수거·서버 전송 상태·캠페인 UTM/DB CPA를 표시한다. Meta 목표는 판매/트래픽 등을 구분하고 엑셀에도 포함한다. UTM 생성기는 공식 공개 랜딩만 허용하며 source/medium/campaign/id/content를 요구한다. 광고 설정은 운영자가 실제 최종 URL에 적용한다.

CRM 실험은 최근 14~90일 구매·마케팅 동의 회원을 고정 50:50 배정한다. 차단·탈퇴·정보 삭제·30일 내 다른 실험은 제외한다. 내려받기 직전에 현재 동의를 재확인한다. 자동 발송은 없으며 대조군에는 메시지를 보내지 않는다. 운영자가 발송 완료를 확인하면 14일 관측을 시작한다. 대상 생성 후 24시간 이내에만 시작할 수 있다. 순매출은 환불 차감이며 비용·기여이익을 따로 대조한다.

## 검증

- `node scripts/test-refunded-inventory.mjs [현재 create_order_core SQL]`
- `node scripts/test-ga-purchase.mjs`
- `node scripts/test-growth-experiments.mjs`
- `node --test api/admin/performance.test.js`
- 공식 `/debug/mp/collect` 검증 오류 0건 확인. 테스트 이벤트는 수집 endpoint로 보내지 않는다. 새 실제 구매의 GA 반영은 처리 지연 후 추가 관측 대상이다.

## 공식 근거

- [GA Measurement Protocol 전송](https://developers.google.com/analytics/devguides/collection/protocol/ga4/sending-events)
- [이벤트 검증](https://developers.google.com/analytics/devguides/collection/protocol/ga4/validating-events)
- [gtag get](https://developers.google.com/tag-platform/gtagjs/reference#get)
- [GA Data API 스키마](https://developers.google.com/analytics/devguides/reporting/data/v1/api-schema)
- [Supabase Vault](https://supabase.com/docs/guides/database/vault)
- [Meta Ads Insights](https://developers.facebook.com/docs/marketing-api/insights/)
