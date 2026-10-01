# 휴대폰 인증과 회원 선택 통합 — 2026-10-01

현재 상태: 구현/로컬 검증 완료, 운영 DB와 인증 설정은 미변경. 친구 초대 1회/링크 만료는 별도 배포 완료.

## 확정 정책

- 초대 링크 첫 성공 때 초대자·친구 각 4,000원 동시 발급, 교재 30,000원 이상·발급 후 30일. 링크 재사용 보상 불가. 친구 본인의 초대 권리는 별도 1회.
- 신규 가입은 국내 010 휴대폰 OTP → 이름/필수 약관. 이메일 인증·비밀번호는 신규 휴대폰 가입에 요구하지 않는다.
- 기존 이메일·카카오·구글 로그인 유지. 미인증 회원은 휴대폰 인증을 완료해야 이용 가능.
- 인증된 번호는 한 활성 계정만 소유. 입력 phone과 실제 인증 소유권은 별도이며 전환 당시 기존 번호만 통합 후보로 보존한다.
- 같은 번호의 계정은 각각 로그인 확인 후 회원이 대표 계정 선택. 번호 일치만으로 타 계정의 주문·포인트를 보여주거나 옮기지 않는다.
- 확인된 계정 전체를 선택한 대표 계정으로 통합한다. 미확인 후보는 이동하지 않는다. 다른 사람의 계정/번호 재할당은 고객센터에서 확인한다.
- 원 계정은 이용 중지 후 기존 30일 개인정보 파기 절차에 편입. 기존 이메일·소셜 로그인 자격을 대표 계정에 임의로 연결하지 않는다. 대표 계정의 기존 로그인 방법과 휴대폰 로그인을 사용한다.

## 확인한 운영 현황

읽기 전용 집계: 회원 1,238명 / 번호 없음 57 / 잘못된 번호 9 / 기존 OTP 인증 47 / 번호 중복 30그룹·63계정. 운영 전환 직전에 `scripts/audit-phone-account-migration.mjs`를 재실행한다. 이 스크립트는 개인정보/키를 출력하지 않는다.

## 데이터 및 접근 제어

- `member_phone_identities`: 인증 번호 유일성. 클라이언트 직접 접근 금지/RLS.
- `member_phone_proofs`: 20분 소유 증명. OTP 오입력 횟수는 실패 응답으로 커밋하여 5회 제한이 롤백되지 않는다.
- `member_merge_requests`: 난수 capability의 해시, 후보 스냅샷, 각 요청 JWT의 `amr` 재로그인 증거. 만료/권한/대표 선택을 DB에서 검증. 단순 토큰 갱신과 다른 기기의 로그인은 소유 증명으로 인정하지 않음.
- `member_account_merges`: 원 계정→대표 계정. 원 계정의 기존 JWT는 Data API 사전 검사·RLS·쓰기 트리거로 제한.
- `member_merge_row_audit`: 통합 전 행 스냅샷. 서비스 전용. 번호/스냅샷은 기존 개인정보 파기 시 함께 제거.
- `member_signup_benefit_claims`: 서버 비밀키로 HMAC한 번호별 혜택 발급 원장. 번호 원문으로 저장하지 않음.
- 주문/수거/판매/정산/포인트는 소유자만 이동하며 금액·계좌 스냅샷·수수료 정책을 변경하지 않는다. 관리자 행위자 이력도 보존한다.
- 동일 상품 장바구니·찜·재입고 알림 중복만 제거. 중복 쿠폰의 기존 사용 이력은 원 계정에 보존하며 추가 사용은 막는다. 이후 환불 복원은 대표 계정의 한 장으로 전달.
- 입금 대기 주문/유효한 카드 결제 세션이 있으면 통합 중단. 미인증 계정의 주문 화면은 차단되므로 입금 완료 또는 고객센터 취소로 해결한다. 결제창만 닫은 세션은 기존 24시간 만료 후 재시도. 자동 취소/환불/승인하지 않는다.
- 모바일 포함 Data API 전체는 `enforce_member_identity_request()`로 보호한다. RLS는 Realtime/직접 테이블 접근도 제한한다. 서비스/관리자 경로는 기존 인증에 따른다.

## 운영 전환 승인 후 순서

루트 `AGENTS.md`의 자동 ship hard-stop에 해당: 새 환경 변수, 인증 서비스 설정, 광범위한 회원 계정 통합. 승인 전에는 아래 적용 단계를 실행하지 않는다.

1. 최신 계정 집계와 양 repo 상태 확인. 타 세션 미추적 SQL을 포함하지 않는다.
2. 아래 4개 migration을 한 묶음으로 dry-run한 뒤 같은 해시의 파일만 적용:
   - `20261001054602_phone_member_identity.sql`
   - `20261001060422_phone_identity_enforcement.sql`
   - `20261001060424_member_selected_account_merge.sql`
   - `20261001060942_phone_verified_referral_rewards.sql`
3. Frontend Production에 `SUPABASE_SEND_SMS_HOOK_SECRET` 신규 등록. Supabase가 발급한 Send SMS Hook 서명 비밀키를 사용하며 화면/로그/커밋에 기록하지 않는다. 기존 SOLAPI/Supabase 서비스 키는 재사용.
4. Supabase Phone provider 활성화, SMS 자동 확인 OFF, OTP 만료 300초. Send SMS Hook의 URI를 `https://subook.kr/api/auth/phone-sms-hook`으로 연결하고 동일한 서명 비밀키 사용. 이메일 자동 확인을 켜지 않는다.
5. 양 repo 검증·명시 파일 commit/push 후 루트 `npm run deploy:public`. Production `READY` 확인. 관리자 앱의 배포는 필요 없음.
6. 기존 PostgREST pre-request 설정 확인(2026-10-01 현재 없음). 다른 설정이 생겼다면 덮어쓰지 말고 합성 검토. `authenticator`의 `pgrst.db_pre_request=public.enforce_member_identity_request`를 설정하고 `NOTIFY pgrst, 'reload config'`.
7. 운영 검증할 휴대폰의 명시적인 테스트 발송 동의를 확보. 정책 행의 `phone_signup_enabled=true`, `merge_enabled=true`, `enabled=true`, `activated_at=now()`를 같은 트랜잭션으로 활성화. 실제 문자 수신·신규 가입·기존 로그인 게이트·대표 계정 통합을 확인한다. 실제 고객 계정은 테스트 목적으로 통합하지 않는다.
8. 번호 유일성, 쿠폰 양쪽 발급 시각/개수, 이전 계정 접근 차단 확인. 검증용 계정은 승인된 범위로 정리한다.

검토용 dry-run 명령(루트):

```powershell
node backend/scripts/apply-reviewed-migration.mjs 20261001054602_phone_member_identity.sql,20261001060422_phone_identity_enforcement.sql,20261001060424_member_selected_account_merge.sql,20261001060942_phone_verified_referral_rewards.sql dry-run
```

Supabase CLI dry-run은 적용 목록만 확인하며 SQL 실행 검증은 하지 않는다. SQL 실행은 PGlite 테스트로 확인했으며 실제 운영 schema/트리거에서의 통합은 활성화 후 별도 검증이 필요하다.

## 장애 시

새 통합을 우선 `merge_enabled=false`로 중단. 강제 인증 장애는 `enabled=false`로 게이트를 해제한다. 이미 휴대폰으로 가입한 회원을 위해 Phone provider/로그인과 최신 frontend는 유지한다. 운영 전환 후 원래 frontend로 단독 롤백하지 않는다.

실제 통합 이력이 생긴 뒤에는 SQL을 역실행하지 않는다. 원 계정 재개/소유자 복원은 request별 스냅샷과 이후 주문·환불을 대조한 뒤 운영자 확인을 거친다. 자동 복원/쿠폰 재발급 금지. 원 계정 파기 전 보관 기간은 30일이다.

## 검증 근거

- PGlite: OTP 실패 횟수, 직접 변조, 번호 중복, hook 예약/멱등, 재로그인 소유 증명, 타인 정보 차단, 실패 시 전체 롤백, 자산 보존, 쿠폰 동시 발급/만료, 환불 복원, 개인정보 파기.
- API 모의 테스트: 표준 webhook 원문 서명/시간 검증, 무서명 발송 차단, 중복 발송 차단, 실패 응답, JWT/서버 인증 번호만 Auth 연결.
- 브라우저 모의 E2E: 신규 휴대폰 OTP→약관(비밀번호 없음), 오입력, 기존 회원 강제 인증→통합, desktop/mobile overflow 및 런타임 오류 없음. 실제 SMS 발송과 실제 고객 통합은 실행하지 않음.
- 공식 근거: [Phone Auth](https://supabase.com/docs/guides/auth/phone-login), [Send SMS Hook](https://supabase.com/docs/guides/auth/auth-hooks/send-sms-hook), [Data API 보안](https://supabase.com/docs/guides/api/securing-your-api), [JWT 인증 증거](https://supabase.com/docs/guides/auth/jwt-fields), [전화번호 확인](https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid), [표준 webhook](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md), [Vercel Web Request](https://vercel.com/docs/functions/runtimes/node-js).
