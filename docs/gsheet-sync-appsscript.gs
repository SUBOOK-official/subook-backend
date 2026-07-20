/**
 * 수북 구글시트 자동 기록 웹앱 (Apps Script)
 * — 운영 스프레드시트에 바인딩해서 배포 (시트 → 확장 프로그램 → Apps Script)
 *
 * DB 트리거(20260720134859_gsheet_sync_notifications.sql)가 pg_net으로 POST:
 *   { token, kind: 'sale' | 'inventory', rows: [...] }
 *   - sale:      rows = 시트 1행 헤더명을 키로 한 객체 배열 → "판매내역(6/8~)"에 기록
 *                (헤더를 읽어 열 위치에 매핑하므로 열 순서가 바뀌어도 동작)
 *   - inventory: rows = [일련번호, 위치, 수거신청자, 상품명, 판매가, 옵션] 배열 배열
 *                → "새 DB(3/30~)" A~F열에 기록
 *
 * 2026-07-20 실검증에서 확인된 시트 특성 때문에 단순 appendRow를 쓰지 않는다:
 *   1) 셀에 남아 있는 날짜 서식 탓에 일련번호(999999)가 "4637. 11. 25"로 표시됐다.
 *      → 값을 쓰기 전에 열별 서식을 지정한다(숫자 "0" / 텍스트 "@").
 *   2) 우편번호 "00000"이 숫자 0으로 바뀌어 앞자리 0이 사라졌다. → 텍스트 서식으로 해결.
 *   3) 판매내역 "정산자명", 새 DB "판매완료여부" 열에는 시트 자체 수식이 들어 있다.
 *      → 값이 없는 열은 아예 건드리지 않는다(빈 문자열로 덮어쓰면 수식이 사라짐).
 *
 * 배포: 우측 상단 배포 → 새 배포 → 유형: 웹 앱 →
 *       실행 계정: 나 / 액세스 권한: 모든 사용자 → 배포 → /exec URL 복사.
 *       URL은 Supabase Vault `gsheet_sync_webhook_url`에 저장.
 *       코드 수정 후에는 "배포 관리 → 편집(연필) → 버전: 새 버전 → 배포"로 올려야
 *       기존 /exec URL이 유지된다(새 배포를 만들면 URL이 바뀜).
 *
 * SHARED_TOKEN은 Vault `gsheet_sync_token` 값과 동일해야 한다 (저장소에는 미기재).
 */

var SHARED_TOKEN = "여기에_토큰_붙여넣기";
var SALES_SHEET_NAME = "판매내역(6/8~)";
var INVENTORY_SHEET_NAME = "새 DB(3/30~)";

// 판매내역 탭에서 숫자로 다뤄야 하는 열 (합계·정산 계산에 쓰이므로 텍스트로 만들면 안 됨)
var SALES_NUMERIC_HEADERS = [
  "단일 정가", "상품 할인 금액", "단일 판매가", "구매 수량", "상품 총액",
  "배송비", "지역별 배송비", "상품 합계 금액", "할인 수단1 - 할인 가격",
  "주문 할인 합계 금액", "배송비 할인 금액", "주문 금액", "결제 완료 금액",
  "환불 총액", "결제1 - 결제 금액", "결제1 - 환불 금액",
  "결제2 - 결제 금액", "결제2 - 환불 금액"
];

// 새 DB 탭 A~F 열 서식 (일련번호·판매가만 숫자, 나머지는 텍스트)
var INVENTORY_FORMATS = ["0", "@", "@", "@", "0", "@"];

function doPost(e) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var payload = JSON.parse(e.postData.contents);
    if (!payload || payload.token !== SHARED_TOKEN) {
      return jsonOut({ ok: false, error: "unauthorized" });
    }

    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var rows = payload.rows || [];
    var appended = 0;

    if (payload.kind === "inventory") {
      var invSheet = ss.getSheetByName(INVENTORY_SHEET_NAME);
      if (!invSheet) return jsonOut({ ok: false, error: "inventory sheet not found" });
      var invStart = invSheet.getLastRow() + 1;
      rows.forEach(function (row, idx) {
        for (var c = 0; c < INVENTORY_FORMATS.length; c++) {
          var value = row[c];
          if (value === null || value === undefined || value === "") continue;
          var cell = invSheet.getRange(invStart + idx, c + 1);
          cell.setNumberFormat(INVENTORY_FORMATS[c]);
          cell.setValue(value);
        }
        appended++;
      });
    } else if (payload.kind === "sale") {
      var saleSheet = ss.getSheetByName(SALES_SHEET_NAME);
      if (!saleSheet) return jsonOut({ ok: false, error: "sales sheet not found" });
      var headers = saleSheet.getRange(1, 1, 1, saleSheet.getLastColumn()).getValues()[0];
      var saleStart = saleSheet.getLastRow() + 1;
      rows.forEach(function (obj, idx) {
        headers.forEach(function (header, c) {
          var key = String(header || "").trim();
          // 값이 없는 열은 건드리지 않는다 — 수식이 들어 있는 열(정산자명 등)을 보호
          if (!key || !Object.prototype.hasOwnProperty.call(obj, key)) return;
          var value = obj[key];
          if (value === null || value === undefined || value === "") return;
          var cell = saleSheet.getRange(saleStart + idx, c + 1);
          cell.setNumberFormat(SALES_NUMERIC_HEADERS.indexOf(key) >= 0 ? "0" : "@");
          cell.setValue(value);
        });
        appended++;
      });
    } else {
      return jsonOut({ ok: false, error: "unknown kind" });
    }

    return jsonOut({ ok: true, appended: appended });
  } catch (err) {
    return jsonOut({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(
    ContentService.MimeType.JSON
  );
}
