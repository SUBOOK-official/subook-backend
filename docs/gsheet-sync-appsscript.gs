/**
 * 수북 구글시트 자동 기록 웹앱 (Apps Script)
 * — 운영 스프레드시트에 바인딩해서 배포 (시트 → 확장 프로그램 → Apps Script)
 *
 * DB 트리거(20260720134859_gsheet_sync_notifications.sql)가 pg_net으로 POST:
 *   { token, kind: 'sale' | 'inventory', rows: [...] }
 *   - sale:      rows = 시트 1행 헤더명을 키로 한 객체 배열 → "판매내역(6/8~)"에 append
 *                (헤더를 읽어 열 위치에 매핑하므로 열 순서가 바뀌어도 동작)
 *   - inventory: rows = [일련번호, 위치, 수거신청자, 상품명, 판매가, 옵션] 배열 배열
 *                → "새 DB(3/30~)" A~F열에 append
 *
 * 배포: 우측 상단 배포 → 새 배포 → 유형: 웹 앱 →
 *       실행 계정: 나 / 액세스 권한: 모든 사용자 → 배포 → /exec URL 복사.
 *       URL은 Supabase Vault `gsheet_sync_webhook_url`에 저장.
 *
 * SHARED_TOKEN은 Vault `gsheet_sync_token` 값과 동일해야 한다 (저장소에는 미기재).
 */

var SHARED_TOKEN = "여기에_토큰_붙여넣기";
var SALES_SHEET_NAME = "판매내역(6/8~)";
var INVENTORY_SHEET_NAME = "새 DB(3/30~)";

function doPost(e) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var payload = JSON.parse(e.postData.contents);
    if (!payload || payload.token !== SHARED_TOKEN) {
      return jsonOut({ ok: false, error: "unauthorized" });
    }

    var ss = SpreadsheetApp.getActiveSpreadsheet();
    var appended = 0;

    if (payload.kind === "inventory") {
      var invSheet = ss.getSheetByName(INVENTORY_SHEET_NAME);
      if (!invSheet) return jsonOut({ ok: false, error: "inventory sheet not found" });
      (payload.rows || []).forEach(function (row) {
        invSheet.appendRow(row.map(function (v) { return v === null ? "" : v; }));
        appended++;
      });
    } else if (payload.kind === "sale") {
      var saleSheet = ss.getSheetByName(SALES_SHEET_NAME);
      if (!saleSheet) return jsonOut({ ok: false, error: "sales sheet not found" });
      var headers = saleSheet.getRange(1, 1, 1, saleSheet.getLastColumn()).getValues()[0];
      (payload.rows || []).forEach(function (obj) {
        var row = headers.map(function (h) {
          var key = String(h || "").trim();
          var v = obj[key];
          return v === undefined || v === null ? "" : v;
        });
        saleSheet.appendRow(row);
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
