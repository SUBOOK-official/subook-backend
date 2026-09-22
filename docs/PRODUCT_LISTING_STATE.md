# 상품 공개 설정과 재고 상태 분리

2026-09-23 KST. **운영 DB 적용·커밋/push·public/admin production 배포 완료.**

## 동작

- `products.is_listed=false`: 숨김. 취소·재입고가 공개 설정을 바꾸지 않는다.
- `is_listed=true`이고 공개 판매 가능 책(`on_sale AND is_public`)이 있으면 판매중, 없으면 품절.
- 상품 숨김은 권별 노출도 해제한다. 명시적으로 상품을 공개하면 기존과 같은 검수 조건을 통과한 재고만 공개한다.
- 권별 비노출은 상품 공개 설정과 별개다. 숨긴 상품의 권별 공개는 거부하며 상품부터 공개해야 한다.
- 구매자 목록/상세/검색은 기존 노출 정책 유지: 일반 품절 제외, 전일학원 모의고사 품절 유지.
- 봇 프리렌더도 명시적 상품 숨김을 적용한다. 사이트맵·Meta 신규 피드에는 판매중 상품만 포함한다.
  Meta 품절 상품의 ID/마지막 가격은 기존 `meta_catalog_snapshots`에서 계속 복원한다.

## 보수적 이관

읽기 전용 조사 시점: 판매중 460종, 숨김 591종, 품절 0종.

| 이관 후 | 상품 수 | 근거 |
| --- | ---: | --- |
| 판매중 | 460 | 현재 공개 판매 가능 재고 존재 |
| 품절 | 208 | 미판매 재고 없음 + 예약/판매 이력 있음 + 마지막 상품 판매중→숨김 전이 시각에 해당 책의 공개 해제와 판매중→예약/판매완료 이력 동시 존재 |
| 숨김 | 383 | 위 공개 근거가 없는 상품. 빈 상품·폐기·명시적 숨김·과거 이력 불충분 상품 포함 |

적용 직전 재조회와 적용 후 실측 모두 위 수치와 일치했다. 상품 ID를 하드코딩하지 않고 적용 시점의 재고/이력으로 판정한다.
`books`의 상태·가격·공개 값, 주문·결제·정산 데이터는 이관하지 않는다.
기존 products RLS(공개 읽기, 관리자만 쓰기)를 유지하고 신규 트리거 함수의 외부 실행을 차단한다.
기존 상태 이력 트리거·옵션 균일성 가드·재고 점검 필드/필터·자체판매 표시를 보존했다.

## 검증

```powershell
node backend/scripts/test-product-listing-state.mjs
npm --prefix frontend run lint
npm --prefix frontend run test:public
npm --prefix frontend/apps/admin-web run build
npm --prefix frontend/apps/public-web run build
```

- PGlite PostgreSQL에서 실제 새 migration, 트리거, 조회/공개 RPC 실행.
- 보수적 이관, 이관 전후 책 데이터 불변 및 구매자 목록/검색 결과 동일 확인.
- 마지막 예약/판매·취소·재입고의 책 상태 전이, 숨김 유지, 직접 상태 덮어쓰기 방지 검증.
- 전일 품절 공개/숨김/재공개, 일반 품절 조회 제외, 관리자 필터/페이지 수, 기존 옵션 가드 확인.
- 비관리자 RPC와 직접 UPDATE 거부, 상태 변경 이력 기록 확인.
- public 테스트 229개, lint, admin/public 빌드 통과.
- 운영 결제/주문 생성 테스트는 실행하지 않았다.

## 운영 적용 결과

`20260922180318_separate_product_listing_from_stock.sql`의 dry-run 성공. 데이터 상태를 바꾸는
`UPDATE ... WHERE`에 대한 hard-stop으로 대기한 뒤, 2026-09-23 사용자 “아 이제 적용하고 배포하자” 승인으로 적용했다.

작업 시작 전에 존재하던 미추적 파일
`20260905031459_fix_create_order_reserved_check_ignore_refunded_items.sql`은 원격 미적용 상태여서
일반 `db push --dry-run`을 막는다. 이 파일을 수정·삭제·repair하거나 `--include-all`로 함께 적용하지 않는다.
검증에서는 추적 중인 기존 migration과 이번 migration만 복사한 별도 workdir로 dry-run했다. 임시 폴더는 정리했다.

실행한 순서:

1. 운영 함수 정의와 이관 대상 수를 재확인한다. 동시 작업으로 정의가 바뀌었으면 차이를 반영하고 재검증한다.
2. 영향받은 frontend/backend 파일만 각각 커밋·push한다.
3. **public-web을 먼저 배포한다.** 프리렌더는 공개 읽기 products 테이블의 단일 행을 `select=*`로 조회하므로
   새 컬럼 도입 전후 모두 동작한다. 일반 품절 프리렌더/사이트맵/Meta 피드 조회 조건을 먼저 준비해
   DB 적용과 앱 배포 사이의 노출 확대·피드 오류를 피한다.
4. 별도 workdir를 다시 구성해 프로젝트 ref/URL 일치 확인 → dry-run → 이번 migration만 push한다.
5. 루트 `npm run deploy:admin`으로 관리자 앱을 배포한다. public/admin 모두 READY/production을 확인한다.
6. 관리자 상태 집계, 판매중·품절·숨김 필터와 검색, 전일 품절/일반 품절의 구매자 노출, Meta 피드 HTTP 응답을 확인한다.

### 배포·사후 검증 기록

- frontend 커밋 `501c408`(구매자 정책 유지), `554593f`(관리자 UI); backend `d02eab5`(migration/테스트). 모두 main push 완료.
- public: https://subook.kr — `dpl_4c5dEN9Ka2qbgj5Zf6ximQdYHbvb`, READY / production, Vite 6.4.2, 빌드 12초.
- admin: https://admin.subook.kr — `dpl_7emvcUMzk1FxDfrY66RtqcYJSG2V`, READY / production, Vite 6.4.2, 빌드 20초.
- migration 목록에서 이번 migration의 local/remote 적용 일치 확인. 무관한 미추적 migration은 적용하지 않았다.
- 상품 1,051종 모두 사전 예상 분류와 일치(차이 0). 구매자 목록 461종의 ID 집합은 전후 동일.
- 책 3,938권 전체 행 fingerprint 전후 동일. 운영 함수 10개가 새 migration 정의와 일치.
- 일반 품절 상품 1 프리렌더 404, 기존 전일 품절 2370 프리렌더 200/OutOfStock. 사이트맵 200/460종 유지.
- Meta 전체/기본 피드 모두 HTTP 200. 관리자 페이지/실제 배포 chunk HTTP 200, is_listed 및 상태 필터 포함 확인.
- 관리자 필터/검색/RPC는 로컬 SQL 테스트로 검증했으며, 로그인한 운영 UI에서 상태를 변경하는 E2E는 실행하지 않았다.
- 배포별 최근 1시간 오류 로그: admin 없음. public은 Node DEP0169 url.parse() 폐기 예정 경고 2건이며 확인한 요청은 정상 응답했다. Drains/Monitoring 별도 설정 점검은 수행하지 않았다.

## 롤백

새 컬럼과 운영자가 선택한 공개 설정은 삭제하지 않는다. 주문·재고 데이터도 복원 덮어쓰기를 하지 않는다.
승인된 별도 rollback migration에서 `products_apply_listing_visibility_trigger`를 제거하고,
`products_enforce_derived_status_trigger`를 이전의 `BEFORE UPDATE OF status`로 복원한다.
아래 이전 정의를 정확히 복원한 뒤 `refresh_storefront_product_status(id)`로 전체 상품 상태를 재계산한다.
마지막으로 frontend를 이 변경 이전 버전으로 배포한다.

- 상태 guard: `20260725041220_products_derived_status_guard.sql`
- 상태 refresh: `20260719162505_product_option_integrity.sql`의 해당 함수만
- 책 공개 guard: `2026051201_relax_books_public_rules.sql`
- 상품 공개 RPC: `20260722191957_register_feedback_batch_a.sql`의 해당 함수만
- 권별 공개 RPC: `2026050606_admin_products_master_rpcs.sql`의 해당 함수만
- 관리자 목록: `20260915062417_direct_sale_products_and_register_sales_history.sql`의 해당 함수만
- 구매자 목록/상세/자동완성: `20260921070327_jeonil_sold_out_storefront.sql`

과거 migration 전체를 재실행하지 않는다. 폐지된 수동 status 변경 RPC 등을 되살릴 수 있다.
