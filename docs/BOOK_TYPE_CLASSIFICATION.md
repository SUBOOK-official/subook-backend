# 상품 유형 분류

2026-09-30 사용자 요청: 전수 점검 수정 후보 43종 교정 및 신규 등록 오분류 방지.

## 등록 기준

- 서버 `_register_classify_book_type`를 등록 화면과 저장 RPC가 함께 사용한다.
- 공식 설명을 확인한 시리즈 또는 한 가지 유형이 명시된 제목에만 유형을 제안한다. 제안의 근거·공식 링크를 표시한다.
- 제목에 근거가 없으면 유형을 비워 둔다. 기본값으로 개념을 지정하지 않는다.
- 혼합형, 월간·일간, EBS 연계, 어휘책, 판본별 구성이 다른 시리즈, 복습·분석 부교재는 직접 확인한다.
- 자동 제안과 다른 유형이나 미확인 유형은 선택값·4~500자 확인 근거·확인 체크가 필요하다. 제목·과목·선택값·근거 변경 시 체크를 초기화한다.
- 저장 RPC도 허용 유형, 확인한 제목·과목, 확인 여부와 근거를 검증한다. 잘못된 행이 있으면 배치 전체를 롤백한다.
- `product_type_reviews`에 선택값과 근거를 기록한다. RLS는 관리자 읽기만 허용하고, 쓰기는 등록 RPC 내부에서 수행한다.
- 기존 상품 재고 추가는 기존 상품 유형을 따른다. 신규/기존 모두 재고 행의 유형도 함께 저장한다.

## 기존 데이터 교정

`scripts/data/book-type-corrections-20260930.json`의 43종만 대상이다. 분류 정책 확인 74종·추가 근거 확인 513종은 오분류로 확정한 목록이 아니므로 일괄 추측해서 변경하지 않는다.

`node backend/scripts/correct-book-types.mjs`는 운영 DB에서 트리거까지 실행하고 롤백한다. `--with-migration`은 신규 schema도 같은 롤백 트랜잭션에 포함한다. `--apply`만 실제 커밋한다.

상품 ID·제목·기존 유형이 점검 당시와 같아야 하고, 그룹 키 충돌이 없어야 한다. 상품과 연결 재고를 함께 수정하며 가격·옵션·공개 상태 등 다른 값이 바뀌면 전체 롤백한다. 실행 전 유형·그룹 키 백업과 결과를 워크스페이스의 `tools/book-type-audit-20260930`에 보관한다. 이 파일은 동일 교정의 재실행 시 기존 유형 검사에서 중단한다.

## 검증

- `node backend/scripts/test-book-type-classification.mjs`: 실제 PostgreSQL 엔진에서 43종, 혼합형, 수동 확인, 전체 롤백, 할인·옵션·일련번호, 권한/RLS를 확인.
- `node --test frontend/apps/admin-web/src/lib/registerBookType.test.js`: 오래된 응답, 구버전 초안, 수정 후 재확인, 조회 장애 시 직접 확인을 검증.
- 분류 규칙 추가 시 공식 출처를 함께 남기고 정상 판본뿐 아니라 부교재·세트·다른 과목도 테스트한다.

공식 API 동작 확인: https://supabase.com/docs/reference/cli/supabase-db-push , https://supabase.com/docs/reference/api/v1-run-a-query
