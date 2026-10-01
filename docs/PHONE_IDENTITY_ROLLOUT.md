# 휴대폰 인증과 회원 선택 통합 — 2026-10-01

현재 정책: **2026-10-01 사용자 정정 — 이메일 필수, 기존 이메일/비밀번호·카카오/구글 가입 유지, 번호 인증 추가.** 전화번호 단독 가입은 오해한 구현이므로 폐지한다. 1번호1계정·기존 회원 강제 인증·대표 선택 통합·친구 초대 1회는 유지한다.

## 이메일 가입 복원

### 신규 중복 가입 처리 (사용자 후속 확정)

모든 회원은 이메일+인증 전화번호가 필수이며 로그인 수단은 이메일/카카오/구글이다. 신규 가입 시 이미 등록된 이메일 또는 인증 번호가 겹치면 **기존 계정으로 로그인 안내**한다. 새 계정을 만든 뒤 통합하지 않는다. 카카오는 서버가 인증된 번호를 받았으면 SMS 생략, 미제공은 SMS. 구글의 번호 미제공도 SMS 처리한다.

일반 회원의 번호 단독 로그인은 SMS hook에서도 차단한다. 앞선 오해로 이미 생긴 이메일 없는 Phone 계정 1개의 이메일 등록 복구만 한시적으로 허용하며, 이메일 등록 이후에는 그 경로도 종료된다.

`20261001091226_reject_duplicate_phone_signup.sql`은 SMS 검증 응답·Before User Created·번호 귀속 트리거에서 중복을 검사한다. SMS 확인 이후 다른 가입자가 먼저 번호를 등록하는 경쟁도 번호 잠금과 트리거로 거부한다. 신규 OAuth 인증 레코드에는 중복 번호로 회원 프로필/쿠폰을 만들지 않는다. `get_my_member_identity()`도 `existing_account`를 반환하므로 카카오 콜백/새로고침에서도 같은 안내가 유지된다. 전체 이메일·번호나 타 계정 자산을 응답하지 않는다.

기존 대표 선택 통합은 `auth.users.created_at < member_identity_policy.activated_at`인 전환 전 계정에만 허용한다. 신규 계정의 직접 통합 RPC 호출과 구버전 미완료 통합 요청도 차단한다. 고객 데이터 삭제나 실제 고객 통합은 수행하지 않는다.

검증: 신규 정책 DB 테스트(카카오 정상/동일 계정 재로그인/구글 중복 SMS/카카오 중복/이메일 사전 차단/경쟁/기존 통합/정상 가입/초대 보상), 모의 브라우저 이메일 중복·구글 SMS 중복·카카오 번호 제공/미제공/중복·모바일, 운영 스키마 롤백 검증.

운영 완료: Backend `6b07239`, Frontend `1f037d9`, production `dpl_41yLYP2sYnEhZQpG54KPV4SkzBFj` READY / production. 적용 migration 이력 확인, 설치된 함수로 중복 SMS/사전 가입 hook/직접 통합 차단을 실행 후 전체 롤백, 운영 Auth의 이메일/번호 없는 가입 거부 확인. 배포 번들 모의 브라우저 검증과 데스크톱/모바일 시각 확인 통과. 실제 카카오 계정 로그인 및 이번 정정 후 실제 SMS 재발송은 하지 않았다.

### 앞선 이메일 필수 전환 이력

2026-10-01 운영 적용 완료: Backend `54cf3a0`, Frontend `1e827cb`, production `dpl_J3Hxbf9ctyyehfVTcMVA2tYdx9uU` — READY / production. 신규 migration 적용 이력 및 Auth hook 설정을 다시 읽어 확인했다. 실제 Auth API에서 번호 증명 없는 이메일 가입과 이메일 없는 번호 가입이 모두 400으로 생성 전에 거부됐다. 검증 중 문자/이메일은 발송하지 않았고 새 테스트 계정도 남지 않았다.

- Migration `20261001080300_restore_email_signup_phone_verification.sql`: 가입 전 SMS 증명 전용 RLS 테이블, Before User Created SQL hook, 이메일 필수, OAuth 프로필 생성 지연, 인증된 카카오 번호 연결. 개인정보 삭제·고객 통합·금액 변경 없음.
- 이메일 가입: SMS 증명 → 기존 이메일 OTP → 비밀번호·이름·약관 완료. 증명은 이메일에 묶이고 1회만 사용한다. metadata에 전화번호를 쓰는 것으로 우회할 수 없다.
- OAuth: 내부 Auth 인증 레코드는 콜백에 필요하지만 회원 프로필은 번호 확인 뒤 생성한다. 이메일이 없는 OAuth도 신규 생성 hook에서 거부한다.
- 카카오: 서버에서 `GET /v1/oidc/userinfo`, JWT의 Kakao identity와 `sub` 일치, `phone_number_verified=true`, 국내 번호 형식을 모두 확인한 경우 추가 SMS 생략. 미제공/연결 실패 시 SMS. 기존 OAuth 동의 스코프를 임의 변경하지 않았다. 실제 카카오 계정의 이 경로는 아직 E2E 확인하지 않았으며 API 모의 테스트로 검증했다.
- Supabase 기본 Kakao provider는 현재 이메일/프로필 위주로 저장하며 전화번호를 매핑하지 않는다. 운영 Auth identities 650건 중 전화번호 필드가 있는 건은 0건이었다(2026-10-01 조사 시점).
- 번호만으로 만들어진 실제 계정 1개는 보존한다. 복구 로그인 후 실제 이메일·비밀번호 등록을 강제한다. Phone provider는 복구용으로 유지하고 새 번호 계정 생성은 hook으로 차단한다.
- Hook 설정: `hook_before_user_created_enabled=true`, `hook_before_user_created_uri=pg-functions://postgres/public/before_member_user_created`. 기존 SMS hook·OAuth·이메일 확인 설정 유지. DB `phone_signup_enabled=false`, `enabled/merge_enabled=true`.
- 검증: frontend 273개, 신규 DB 정책 7개 및 기존 회귀 10개, lint/public/admin build, 모의 브라우저 이메일가입·복구게이트·통합. 운영 스키마에서 증명/가입/카카오 연결/쿠폰/통합 실행 후 트랜잭션 전체 롤백 성공. 실제 문자 재발송과 실제 고객 계정 통합은 하지 않았다.
- 복구: hook 오류는 해당 hook만 해제하여 원인을 점검한다. 이메일 필수 화면과 고객 데이터/통합 원장은 보존한다. 전화번호 단독 가입 화면으로 되돌리지 않는다.

공식 근거: [가입 생성 전 hook](https://supabase.com/docs/guides/auth/auth-hooks/before-user-created-hook), [SQL hook 권한·URI](https://supabase.com/docs/guides/auth/auth-hooks), [카카오 UserInfo](https://developers.kakao.com/docs/ko/kakaologin/rest-api#oidc-user-info), [Supabase Kakao provider](https://github.com/supabase/auth/blob/master/internal/api/provider/kakao.go).

## 아래는 최초 운영 전환 이력 (이메일 관련 정책은 위 정정이 우선)

운영 검증: 실제 SMS 수신·OTP 인증 성공, 인증되지 않은 중복 계정의 Data API 403, 실서비스 대표 선택 화면/마스킹/모바일 표시를 확인했다. 임시 계정은 자산이 없음을 확인 후 삭제했고 기존 회원은 통합하지 않았다. 실제 DB 스키마와 트리거의 통합/가입/초대 발급은 트랜잭션에서 실행 후 전체 롤백했다.

배포: Frontend `e5b688d`, Backend `b2c340f`. Production `dpl_jm6j4PTfiDSqsCxY7XyrFdyEx1Vq` — READY. 현재 `enabled`, `phone_signup_enabled`, `merge_enabled` 모두 true.

## 확정 정책

- 초대 링크 첫 성공 때 초대자·친구 각 4,000원 동시 발급, 교재 30,000원 이상·발급 후 30일. 링크 재사용 보상 불가. 친구 본인의 초대 권리는 별도 1회.
- 신규 가입은 이메일 필수·기존 이메일/소셜 흐름에 국내 010 번호 인증을 추가한다. 번호 단독 가입 정책은 폐지했다.
- 기존 이메일·카카오·구글 로그인 유지. 미인증 회원은 휴대폰 인증을 완료해야 이용 가능.
- 인증된 번호는 한 활성 계정만 소유. 입력 phone과 실제 인증 소유권은 별도이며 전환 당시 기존 번호만 통합 후보로 보존한다.
- 같은 번호의 계정은 각각 로그인 확인 후 회원이 대표 계정 선택. 번호 일치만으로 타 계정의 주문·포인트를 보여주거나 옮기지 않는다.
- 확인된 계정 전체를 선택한 대표 계정으로 통합한다. 미확인 후보는 이동하지 않는다. 다른 사람의 계정/번호 재할당은 고객센터에서 확인한다.
- 원 계정은 이용 중지 후 기존 30일 개인정보 파기 절차에 편입. 기존 이메일·소셜 로그인 자격을 대표 계정에 임의로 연결하지 않는다. 대표 계정의 기존 로그인 방법과 휴대폰 로그인을 사용한다.

## 확인한 운영 현황

전환 직전 집계: 회원 1,238명 / 번호 없음 57 / 잘못된 번호 9 / 기존 OTP 인증 47 / 번호 중복 30그룹·63계정. 인증된 번호에도 1그룹·2계정 중복이 있어 단독 인증 45계정만 자동 승계했다. 중복 2계정은 인증 증거를 보존하고 재인증 후 회원 선택으로 통합한다. 조사 스크립트 `scripts/audit-phone-account-migration.mjs`는 개인정보/키를 출력하지 않는다.

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

루트 `AGENTS.md`의 자동 ship hard-stop에 해당했던 새 환경 변수·인증 서비스 설정·회원 계정 통합은 2026-10-01 사용자가 운영 전환을 명시 승인했다. 아래는 실제 적용 순서 및 재현 절차다.

1. 최신 계정 집계와 양 repo 상태 확인. 타 세션 미추적 SQL을 포함하지 않는다.
2. 아래 4개 migration을 한 묶음으로 dry-run한 뒤 같은 해시의 파일만 적용:
   - `20261001054602_phone_member_identity.sql`
   - `20261001060422_phone_identity_enforcement.sql`
   - `20261001060424_member_selected_account_merge.sql`
   - `20261001060942_phone_verified_referral_rewards.sql`
3. Frontend Production에 `SUPABASE_SEND_SMS_HOOK_SECRET` 신규 등록. 표준 `v1,whsec_` 형식의 새 32바이트 난수 서명 키를 생성해 Supabase와 동일하게 설정하며 화면/로그/커밋에 기록하지 않는다. 기존 SOLAPI/Supabase 서비스 키는 재사용.
4. Supabase Phone provider 활성화, SMS 자동 확인 OFF, OTP 만료 300초. Send SMS Hook의 URI를 `https://subook.kr/api/auth/phone-sms-hook`으로 연결하고 동일한 서명 비밀키 사용. 이메일 자동 확인을 켜지 않는다.
5. 양 repo 검증·명시 파일 commit/push 후 루트 `npm run deploy:public`. Production `READY` 확인. 관리자 앱의 배포는 필요 없음.
6. 기존 PostgREST pre-request 설정 확인(2026-10-01 현재 없음). 다른 설정이 생겼다면 덮어쓰지 말고 합성 검토. `authenticator`의 `pgrst.db_pre_request=public.enforce_member_identity_request`를 설정하고 `NOTIFY pgrst, 'reload config'`.
7. 운영 검증할 휴대폰의 명시적인 테스트 발송 동의를 확보. 정책 행의 `phone_signup_enabled=true`, `merge_enabled=true`, `enabled=true`, `activated_at=now()`를 같은 트랜잭션으로 활성화. 실제 문자 수신·신규 가입·기존 로그인 게이트·대표 계정 통합을 확인한다. 실제 고객 계정은 테스트 목적으로 통합하지 않는다.
8. 번호 유일성, 쿠폰 양쪽 발급 시각/개수, 이전 계정 접근 차단 확인. 검증용 계정은 승인된 범위로 정리한다.

검토용 dry-run 명령(루트):

```powershell
node backend/scripts/apply-reviewed-migration.mjs 20261001054602_phone_member_identity.sql,20261001060422_phone_identity_enforcement.sql,20261001060424_member_selected_account_merge.sql,20261001060942_phone_verified_referral_rewards.sql dry-run
```

Supabase CLI dry-run은 적용 목록만 확인하며 SQL 실행 검증은 하지 않는다. SQL은 PGlite 테스트와 실제 운영 스키마의 롤백 트랜잭션으로 검증했다.

운영 전환에서 발견한 차이: `complete_member_auth_sms_hook()`은 void RPC라 PostgREST가 204/빈 본문을 반환한다. 발송 성공 후 JSON 파싱 실패로 인증이 취소되지 않도록 빈 응답을 허용하고 테스트에 204 응답을 사용한다. 첫 실제 발송에서 발견 후 플래그를 일시 해제해 수정 배포했고, 두 번째 발송/OTP 검증 성공 후 정상 운영 상태를 확인했다.

## 장애 시

새 통합을 우선 `merge_enabled=false`로 중단. 강제 인증 장애는 `enabled=false`로 게이트를 해제한다. 이미 휴대폰으로 가입한 회원을 위해 Phone provider/로그인과 최신 frontend는 유지한다. 운영 전환 후 원래 frontend로 단독 롤백하지 않는다.

실제 통합 이력이 생긴 뒤에는 SQL을 역실행하지 않는다. 원 계정 재개/소유자 복원은 request별 스냅샷과 이후 주문·환불을 대조한 뒤 운영자 확인을 거친다. 자동 복원/쿠폰 재발급 금지. 원 계정 파기 전 보관 기간은 30일이다.

## 검증 근거

- PGlite: OTP 실패 횟수, 직접 변조, 번호 중복, hook 예약/멱등, 재로그인 소유 증명, 타인 정보 차단, 실패 시 전체 롤백, 자산 보존, 쿠폰 동시 발급/만료, 환불 복원, 개인정보 파기.
- API 모의 테스트: 표준 webhook 원문 서명/시간 검증, 무서명 발송 차단, 중복 발송 차단, 실패 응답, JWT/서버 인증 번호만 Auth 연결.
- 브라우저 모의 E2E: 신규 휴대폰 OTP→약관(비밀번호 없음), 오입력, 기존 회원 강제 인증→통합, 기존 이메일 미인증 계정의 휴대폰 전환, desktop/mobile overflow 및 런타임 오류 없음.
- 운영 E2E: 사용자에게 동의받은 번호의 SMS 수신→OTP 확인→기존 계정 통합 후보 화면. 기존 계정의 상세 자산은 로그인 전 비공개, 통합 버튼 비활성 확인. 고객 계정 통합은 실행하지 않음. 테스트 계정/미제출 통합 요청 정리 완료.
- 최종 검증: frontend 271개, backend 18개, lint/public/admin build 통과. 운영 발송 서명 검증/204 완료 응답 및 신규 가입 페이지 확인.
- 공식 근거: [Phone Auth](https://supabase.com/docs/guides/auth/phone-login), [Send SMS Hook](https://supabase.com/docs/guides/auth/auth-hooks/send-sms-hook), [Data API 보안](https://supabase.com/docs/guides/api/securing-your-api), [JWT 인증 증거](https://supabase.com/docs/guides/auth/jwt-fields), [전화번호 확인](https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid), [표준 webhook](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md), [Vercel Web Request](https://vercel.com/docs/functions/runtimes/node-js).
