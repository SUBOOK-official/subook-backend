// 새 재고 엑셀(current-stock.json)과 우리 DB(books 테이블) 비교.
// 매칭 키: (seller_name, title, option) — 정규화된 lower trim
// 출력:
//   - in_excel_only.json: 엑셀에만 있는 row (DB에 없음 — 새로 INSERT 필요)
//   - in_db_only.json:    DB에만 있는 row (엑셀에 없음 — 이미 팔렸거나 폐기)
//   - matched.json:       양쪽 매칭된 pair (필요 시 update)

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(`${__dirname}/output`);
mkdirSync(outDir, { recursive: true });

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || `https://${process.env.SUPABASE_PROJECT_REF}.supabase.co`;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

function norm(s) {
  return (s ?? "").toString().trim().toLowerCase();
}
function key(seller, title, option) {
  return `${norm(seller)}|${norm(title)}|${norm(option)}`;
}

const excel = JSON.parse(readFileSync(`${outDir}/current-stock.json`, "utf-8"));
console.log(`Excel rows: ${excel.length}`);

// DB에서 books + shipments(seller_name) 가져오기
const allBooks = [];
let from = 0;
const pageSize = 1000;
while (true) {
  const { data, error } = await sb
    .from("books")
    .select("id, title, option, status, shipment_id, price, condition_grade, shipments(seller_name, seller_phone)")
    .range(from, from + pageSize - 1);
  if (error) { console.error(error); process.exit(1); }
  if (!data || data.length === 0) break;
  allBooks.push(...data);
  if (data.length < pageSize) break;
  from += pageSize;
}
console.log(`DB books: ${allBooks.length}`);

// 매칭
const excelMap = new Map(); // key → excel row(s)
for (const e of excel) {
  const k = key(e.seller, e.title, e.option);
  if (!excelMap.has(k)) excelMap.set(k, []);
  excelMap.get(k).push(e);
}

const dbMap = new Map(); // key → db row(s)
for (const b of allBooks) {
  const k = key(b.shipments?.seller_name, b.title, b.option);
  if (!dbMap.has(k)) dbMap.set(k, []);
  dbMap.get(k).push(b);
}

const inExcelOnly = [];
const inDbOnly = [];
const matched = [];

for (const [k, excelRows] of excelMap.entries()) {
  const dbRows = dbMap.get(k) || [];
  // pair off one-to-one as long as both have items
  for (let i = 0; i < excelRows.length; i += 1) {
    if (dbRows[i]) {
      matched.push({ excel: excelRows[i], db: dbRows[i] });
    } else {
      inExcelOnly.push(excelRows[i]);
    }
  }
}
for (const [k, dbRows] of dbMap.entries()) {
  const excelRows = excelMap.get(k) || [];
  for (let i = excelRows.length; i < dbRows.length; i += 1) {
    inDbOnly.push(dbRows[i]);
  }
}

writeFileSync(`${outDir}/in_excel_only.json`, JSON.stringify(inExcelOnly, null, 2));
writeFileSync(`${outDir}/in_db_only.json`, JSON.stringify(inDbOnly, null, 2));
writeFileSync(`${outDir}/matched.json`, JSON.stringify(matched, null, 2));

console.log("\n=== Diff summary ===");
console.log(`Matched (both):        ${matched.length}`);
console.log(`In excel only (new):   ${inExcelOnly.length}`);
console.log(`In DB only (settled?): ${inDbOnly.length}`);

// in_excel_only 셀러별 분포
const excelOnlyBySeller = {};
for (const e of inExcelOnly) excelOnlyBySeller[e.seller || "(none)"] = (excelOnlyBySeller[e.seller || "(none)"] ?? 0) + 1;
console.log("\n=== Excel only — by seller ===");
Object.entries(excelOnlyBySeller).sort((a, b) => b[1] - a[1]).slice(0, 15).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

// in_db_only 셀러별 + status별
const dbOnlyBySeller = {};
const dbOnlyByStatus = {};
for (const b of inDbOnly) {
  const s = b.shipments?.seller_name || "(none)";
  dbOnlyBySeller[s] = (dbOnlyBySeller[s] ?? 0) + 1;
  dbOnlyByStatus[b.status] = (dbOnlyByStatus[b.status] ?? 0) + 1;
}
console.log("\n=== DB only — by seller ===");
Object.entries(dbOnlyBySeller).sort((a, b) => b[1] - a[1]).slice(0, 15).forEach(([k, v]) => console.log(`  ${k}: ${v}`));
console.log("\n=== DB only — by status ===");
Object.entries(dbOnlyByStatus).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

// 판매완료여부가 '판매완료'인 excel row 카운트 (DB에선 settled이어야)
const excelSold = excel.filter(e => e.soldFlag === "판매완료").length;
const matchedSold = matched.filter(m => m.excel.soldFlag === "판매완료").length;
console.log(`\nExcel '판매완료' rows:                ${excelSold}`);
console.log(`Matched + excel says '판매완료':      ${matchedSold}`);
