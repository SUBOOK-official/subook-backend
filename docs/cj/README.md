# CJ대한통운 택배 표준 API — 참고 규격서

- **정본**: `CJLAPI-택배표준API-DeveloperGuide-V3.9.4.pdf` (CJ 개발자포털 자료실 배포본)
- **검색용 텍스트 추출본**: `CJLAPI-DeveloperGuide-V3.9.4.txt` (전 52p, 페이지 마커 `===== PAGE n =====`)
- 코드 위치: `backend/api/admin/cj-pickup.js`, `cj-tracking.js` (= `frontend/apps/admin-web/api/admin/`에 동일 미러, admin.subook.kr 배포본)

## ⭐ 인증 모델 (규격서 p6 · p9 · p49) — 가장 중요, 과거 401의 원인

헤더 `CJ-Gateway-APIKey` 값 규칙:
- **1Day 토큰 발행(`/ReqOneDayToken`)**: Key **생략** (아무 값이나 무시됨). Body `{DATA:{CUST_ID, BIZ_REG_NUM}}` → 응답 `DATA.TOKEN_NUM`.
- **그 외 모든 업무 API**: 헤더 `CJ-Gateway-APIKey` = 방금 받은 **1Day 토큰**(TOKEN_NUM과 동일 값). Body에도 `TOKEN_NUM` 동일 값.

> p49 원문: "OneDayToken 응답의 키값을 CJ-Gateway-APIKey에 값으로 넣어야 하고, Body의 TOKEN_NUM에도 같은 값을 넣어야 한다. 다른 API들도 같은 방식."

⚠️ 2026-07-04까지 헤더에 규격서 **예시 키**(`332d248e-…be2` 계열)를 넣어 업무 API가 전부 `E401 "발급된 인증키를 확인 해주세요"` 였음. 2026-07-05 이 규칙대로 고쳐 **채번(ReqInvcNo) 200 성공(INVC_NO 발급) 검증**. → CJ 승인 문제 아니었음.

## 엔드포인트 (p6)

| 업무 | 개발(:5054) / 운영(:5052) 경로 |
|---|---|
| 1Day 토큰 | `/ReqOneDayToken` |
| 주소정제 | `/ReqAddrRfnSm` (예약접수 시 필수) |
| 상품추적(운송장기준) | `/ReqOneGdsTrc` |
| 운송장번호 생성(채번) | `/ReqInvcNo` (자체 출력 시 필수) |
| (일반)예약접수 | `/RegBook` |
| (일반)예약취소 | `/CnclBook` |
| (일반)상품추적(예약기준) | `/ReqMssGdsTrc` / 수신확정 `/RcvMssGdsTrcCnfrm` |
| (중개) | `/RegBrkrBook` 등 `*Brkr*` |

- 개발: `https://dxapi-dev.cjlogistics.com:5054`, 운영: `https://dxapi.cjlogistics.com:5052`
- 응답 래퍼: `RESULT_CD` `S`/`S200`=성공, `E`/`E4xx`=실패, `RESULT_DETAIL` 메시지. 인코딩 UTF-8(단 일부 에러문구 EUC-KR로 옴).
- 토큰 유효 24h. 발급 1초 2회 이상 요청 시 차단. 401 시 1분 뒤 재발급 권장.

## FAQ 핵심

- **1.4.1 "고객사코드 없음" 에러** (p46): CUST_ID ↔ BIZ_REG_NUM 매칭 확인. 사업자번호는 **대한통운에 등록된 "청구 사업자번호"**(대표 사업자번호와 다를 수 있음). 하이픈 없이 숫자만.
- **1.4.2 사업자번호 수정**: 프로필 화면 하단에서 수정.
- **1.4.10.1 예약접수는 단건만**: 대량도 단건 API 반복 호출. (박스 여러개도 건별)

## 🚦 운영 전환(production 오픈) 절차 (p45 `1.3.15` · p50 `1.4.5`)

셀프로 안 됨. **계약지사 담당자를 통해 개발요청(SR)이 접수**되어야 오픈.
1. 개발(테스트) 검증 완료 → CJ 내부 검증.
2. **운영 승인 요청 양식** 작성 후 계약지사 담당자와 협의:
   고객사코드 / 고객사명 / 월 예상 출고량 / API 연동 시간대 / 전산 담당자(연락처) /
   출력주체(자체출력 여부) / 사용 API 목록(예약접수·예약취소·채번·주소정제·상품추적 각 사용/미사용).
3. **운송장 자체 출력 고객사**면 운송장 샘플 출력·스캔 검증 후 샘플을 메일 제출.
4. 문의·진행 메일: **openapi@cjlogistics.com** (EAI 팀).

## 연락처
- 기술/운영 문의 메일: **openapi@cjlogistics.com**
- 계약/고객코드/여신 문제: **계약지사(대리점) 담당자**
- 자료실에 POSTMAN 컬렉션 샘플 있음.
