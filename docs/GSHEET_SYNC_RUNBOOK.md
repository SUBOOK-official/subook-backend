# 구글시트 동기화 운영

## 전송 구조 (2026-09-23)

- `gsheet_sync_enqueue`는 DB에만 적재한다. 즉시 HTTP를 발송하지 않는다.
- `subook-gsheet-sync-sweep`는 매분 실행한다. advisory lock과 미완료 `sent` 확인으로 HTTP 요청 하나만 진행한다.
- 재고는 최대 20건을 HTTP 1개로 묶는다. 판매는 주문당 HTTP 1개다. HTTP timeout은 120초다.
- 실패 후 5~60분 간격으로 최대 10회 시도한다. `next_attempt_at` 순서로 새 요청이 오래된 재시도에 막히지 않게 한다.
- Apps Script v3 ping 확인 전에는 쓰기 요청을 보내지 않는다. 버전 확인은 하루마다 갱신한다.
- JSON의 `ok: true`를 파싱한다. HTML 페이지에 `not found`가 들어 있다고 인증/설정 오류로 단정하지 않는다.
- 일련번호 없는 재고는 적재하지 않는다. 나중에 일련번호가 배정되면 UPDATE 트리거로 적재한다.
- Apps Script는 빈 식별자를 쓰기 전에 거부하고, 동일 재고의 재전송/배치 내 중복을 제거한다. 쓰기를 flush한 뒤 락을 해제한다.
- 이미 주문번호가 있는 판매내역은 품목 수와 기존 값을 확인한다. 같은 행의 빈 필드만 채우며, 충돌은 `existing_order_conflict`로 운영 점검 대상에 남긴다.

## 실패 복구

1. `gsheet_sync_outbox`의 `kind`, `dedupe_key`, `last_error`, `resolved_at`을 조회한다.
2. 운영 원장의 판매내역/재고와 먼저 대조한다. timeout은 시트 쓰기 실패의 증거가 아니다.
3. 이미 있는 행은 모든 필요한 필드를 확인한 뒤 재전송 없이 확인 처리한다. 원본 실패 이력은 복구 전 백업한다.
4. 정상 결제 주문의 누락은 `admin_gsheet_resend_order(주문번호)`로 기존 failed 행을 재사용한다. 이 함수는 전액/부분 환불을 자동 재전송하지 않는다.
5. 재고 누락은 현재 `books`의 존재/일련번호를 검증하고 현재 빌더 값으로 해당 아웃박스를 재시도한다. 삭제된 교재를 되살리지 않는다.
6. 전액 환불·삭제된 원본 등 의도적으로 전송하지 않을 기록은 근거를 `resolution_note`, 처리 시각을 `resolved_at`에 보존한다. 성공하지 않은 전송을 `confirmed`로 위장하지 않는다.
7. 중복 정리는 원장 백업 후 진행한다. 다른 탭의 행 참조가 있어 행 자체를 삭제하지 않고, 확정된 중복의 자동 입력 영역만 비운다. 수식/수동 입력은 보존한다.

정상 일일 Slack 리포트는 유지한다. 해결된 실패는 제외하고, 미해결 실패와 1시간 이상 미확인 전송을 알린다. 알림만 없애기 위한 실패 기록 삭제는 하지 않는다.

## 배포와 검증

- Apps Script: `docs/gsheet-sync-appsscript.gs`를 기존 Code.gs에 반영한다. 실제 토큰과 다른 스크립트 파일은 보존한다.
- **여러 활성 배포가 있다. Vault의 운영 webhook URL과 일치하는 배포를 갱신해야 한다.** 최신 번호의 다른 배포를 선택하지 않는다.
- 기존 배포의 새 버전을 생성한다. 인증 승인 후 실제 운영 URL에 `kind: ping`을 보내 `ok=true, v=3`을 확인한다.
- DB: migrations `20260923061105`, `20260923062855`를 dry-run으로 확인한 뒤 적용한다. 기존 앱의 Vercel 배포는 필요 없다.
- 테스트: `node --test backend/tests/gsheet-sync.test.js`, `node backend/scripts/test-gsheet-delivery.mjs` (루트에서 실행).
- 운영 확인: 아웃박스 `confirmed`만 확인하지 말고 시트의 행/금액도 다시 대조한다. health RPC는 Slack을 발송하므로 읽기 점검 용도로 호출하지 않는다.

## 확인한 공식 문서

- [pg_net 비동기 요청/timeout](https://supabase.com/docs/guides/database/extensions/pg_net)
- [Apps Script 배포 버전 관리](https://developers.google.com/apps-script/concepts/deployments)
- [Lock와 쓰기 flush](https://developers.google.com/apps-script/reference/lock/lock)
- [Google 서비스 인증](https://developers.google.com/apps-script/guides/services/authorization)
