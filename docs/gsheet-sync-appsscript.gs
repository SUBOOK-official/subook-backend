/**
 * 수북 구글시트 자동 기록 웹앱 (Apps Script) — v2
 * — 운영 스프레드시트에 바인딩해서 배포 (시트 → 확장 프로그램 → Apps Script)
 *
 * DB 트리거/스윕(20260804033000_gsheet_sync_outbox_retry.sql)이 pg_net으로 POST:
 *   { token, kind: 'sale' | 'inventory' | 'ping', rows: [...] }
 *   - sale:      rows = 시트 1행 헤더명을 키로 한 객체 배열 → "판매내역(6/8~)"에 기록
 *                (헤더를 읽어 열 위치에 매핑하므로 열 순서가 바뀌어도 동작)
 *   - inventory: rows = [일련번호, 위치, 수거신청자, 상품명, 판매가, 옵션] 배열 배열
 *                → "새 DB(3/30~)" A~F열에 기록
 *   - ping:      시트 접근 없이 {ok:true, v:2} 응답 — DB 스윕이 v2 배포 여부를
 *                감지하는 용도(재전송은 v2 확인 후에만 시작된다)
 *
 * ── v2 변경 (2026-08-04, ORD-2608-0069/0072/0073 유실 사고 수리) ──
 *   1) 락 유실 수리: 기존 lock.waitLock(20000)이 try/catch "바깥"에 있어
 *      대기 20초 초과 시 예외 → 요청째 유실됐다(동시 3건 중 1건만 기록된 원인).
 *      → tryLock(240000)을 try 안에서 수행, 실패 시에도 JSON 에러 응답.
 *   2) 속도 수리: 행마다 구간별 setValues/setNumberFormats를 반복해 1건에 25초+
 *      (다품목 주문은 수 분) 걸리며 락을 점유했다.
 *      → 전 행을 "연속 열 구간 × N행 블록"으로 묶어 구간당 2회 호출로 일괄 쓰기.
 *   3) 멱등성: 이미 시트에 있는 주문번호(판매)·일련번호(재고)는 건너뛴다.
 *      DB 스윕이 타임아웃 응답을 재전송해도 중복 행이 생기지 않는 전제 조건.
 *
 * 2026-07-20 실검증에서 확인된 시트 특성은 그대로 반영:
 *   - 날짜서식 잔재 → 값 쓰기 전에 서식 지정(숫자 "0" / 텍스트 "@")
 *   - 우편번호 앞자리 0 → 텍스트("@") 서식
 *   - 판매내역 "정산자명", 새 DB "판매완료여부" 열은 시트 자체 수식
 *     → 페이로드에 없는 열이라 블록 쓰기 구간에 포함되지 않음(계속 보존됨)
 *
 * 배포: 코드 수정 후 "배포 관리 → 편집(연필) → 버전: 새 버전 → 배포"로 올려야
 *       기존 /exec URL이 유지된다(새 배포를 만들면 URL이 바뀜).
 *       URL은 Supabase Vault `gsheet_sync_webhook_url`에 저장돼 있다.
 *
 * SHARED_TOKEN은 Vault `gsheet_sync_token` 값과 동일해야 한다 (저장소에는 미기재).
 */

var SHARED_TOKEN = "여기에_토큰_붙여넣기";
var SALES_SHEET_NAME = "판매내역(6/8~)";
var INVENTORY_SHEET_NAME = "새 DB(3/30~)";
var SALES_ORDER_NO_HEADER = "주문 번호";

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
  try {
    var payload = JSON.parse(e.postData.contents);
    if (!payload || payload.token !== SHARED_TOKEN) {
      return jsonOut({ ok: false, v: 2, error: "unauthorized" });
    }
    // ping은 시트·락 없이 즉답 — DB 스윕의 v2 배포 감지용
    if (payload.kind === "ping") {
      return jsonOut({ ok: true, v: 2, pong: true });
    }

    var lock = LockService.getScriptLock();
    // 락 대기는 try 안에서, 충분히 길게(4분 — Apps Script 실행 상한 6분 이내).
    // v1은 waitLock(20000)이 try 밖에 있어 대기 초과 시 요청째 유실됐다.
    if (!lock.tryLock(240000)) {
      return jsonOut({ ok: false, v: 2, error: "lock_timeout" });
    }
    try {
      var rows = payload.rows || [];
      if (payload.kind === "inventory") return jsonOut(appendInventory(rows));
      if (payload.kind === "sale") return jsonOut(appendSales(rows));
      return jsonOut({ ok: false, v: 2, error: "unknown kind" });
    } finally {
      lock.releaseLock();
    }
  } catch (err) {
    return jsonOut({ ok: false, v: 2, error: String(err) });
  }
}

function appendSales(rows) {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SALES_SHEET_NAME);
  if (!sheet) return { ok: false, v: 2, error: "sales sheet not found" };

  var lastCol = sheet.getLastColumn();
  var headers = sheet.getRange(1, 1, 1, lastCol).getValues()[0].map(function (h) {
    return String(h || "").trim();
  });
  var lastRow = sheet.getLastRow();

  // 멱등성: 이미 기록된 주문번호는 건너뛴다 (재전송이 중복 행을 만들지 않게)
  var skipped = 0;
  var orderCol = headers.indexOf(SALES_ORDER_NO_HEADER) + 1;
  if (orderCol > 0 && lastRow >= 2) {
    var existing = {};
    sheet.getRange(2, orderCol, lastRow - 1, 1).getValues().forEach(function (r) {
      var v = String(r[0] || "").trim();
      if (v) existing[v] = true;
    });
    rows = rows.filter(function (obj) {
      var no = String(obj[SALES_ORDER_NO_HEADER] || "").trim();
      if (no && existing[no]) { skipped++; return false; }
      return true;
    });
  }
  if (rows.length === 0) return { ok: true, v: 2, appended: 0, skipped: skipped };

  // 값이 있는 열의 합집합 → 연속 구간 → 구간마다 N행 블록을 한 번에 쓴다.
  // (v1의 행×구간별 개별 호출은 무거운 시트에서 1건 25초+ → 락 점유 장기화의 원흉)
  // 수식 열(정산자명 등)은 페이로드에 키가 없어 구간에 포함되지 않는다.
  var used = {};
  rows.forEach(function (obj) {
    headers.forEach(function (key, c) {
      if (!key || !Object.prototype.hasOwnProperty.call(obj, key)) return;
      var v = obj[key];
      if (v === null || v === undefined || v === "") return;
      used[c] = true;
    });
  });
  var cols = Object.keys(used).map(Number).sort(function (a, b) { return a - b; });
  if (cols.length === 0) return { ok: true, v: 2, appended: 0, skipped: skipped };

  var startRow = lastRow + 1;
  var i = 0;
  while (i < cols.length) {
    var s = i;
    while (i + 1 < cols.length && cols[i + 1] === cols[i] + 1) i++;
    var segCols = cols.slice(s, i + 1);
    var formats = rows.map(function () {
      return segCols.map(function (c) {
        return SALES_NUMERIC_HEADERS.indexOf(headers[c]) >= 0 ? "0" : "@";
      });
    });
    var values = rows.map(function (obj) {
      var v;
      return segCols.map(function (c) {
        v = obj[headers[c]];
        return v === null || v === undefined ? "" : v;
      });
    });
    var range = sheet.getRange(startRow, segCols[0] + 1, rows.length, segCols.length);
    range.setNumberFormats(formats); // 서식 먼저 (날짜서식 잔재로 값이 변형되는 것 방지)
    range.setValues(values);
    i++;
  }
  return { ok: true, v: 2, appended: rows.length, skipped: skipped };
}

function appendInventory(rows) {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(INVENTORY_SHEET_NAME);
  if (!sheet) return { ok: false, v: 2, error: "inventory sheet not found" };

  var lastRow = sheet.getLastRow();

  // 멱등성: A열 일련번호가 이미 있으면 건너뛴다
  var skipped = 0;
  if (lastRow >= 2) {
    var existing = {};
    sheet.getRange(2, 1, lastRow - 1, 1).getValues().forEach(function (r) {
      var v = String(r[0] || "").trim();
      if (v) existing[v] = true;
    });
    rows = rows.filter(function (row) {
      var serial = String(row[0] === null || row[0] === undefined ? "" : row[0]).trim();
      if (serial && existing[serial]) { skipped++; return false; }
      return true;
    });
  }
  if (rows.length === 0) return { ok: true, v: 2, appended: 0, skipped: skipped };

  // A~F 통째 N행 블록 쓰기 — 수식 열(판매완료여부)은 F 뒤라 건드리지 않는다
  var values = rows.map(function (row) {
    return INVENTORY_FORMATS.map(function (_, c) {
      var v = row[c];
      return v === null || v === undefined ? "" : v;
    });
  });
  var formats = rows.map(function () { return INVENTORY_FORMATS.slice(); });
  var range = sheet.getRange(lastRow + 1, 1, rows.length, INVENTORY_FORMATS.length);
  range.setNumberFormats(formats);
  range.setValues(values);
  return { ok: true, v: 2, appended: rows.length, skipped: skipped };
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(
    ContentService.MimeType.JSON
  );
}
