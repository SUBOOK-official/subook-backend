// 엑셀의 모든 책이 DB에 등록됐는지 정확하게 검증.
//
// diff-stock-vs-db는 셀러명 정확 일치만 매칭해서 false negative가 있음:
//   - 엑셀 "매입" ↔ DB "수북 자체 매입"
//   - 엑셀 "1"  ↔ DB "정희원"
// 이걸 정규화 후 비교.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(`${__dirname}/output`);

const sb = createClient(
  process.env.VITE_SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

function normSeller(s) {
  if (s == null) return "";
  const t = String(s).trim();
  if (t === "" || t === "매입") return "수북 자체 매입";
  if (t === "1") return "정희원";
  return t;
}
function norm(s) {
  return (s ?? "").toString().trim().toLowerCase();
}
function key(seller, title, option) {
  return `${normSeller(seller)}|${norm(title)}|${norm(option)}`;
}

const excel = JSON.parse(readFileSync(`${outDir}/current-stock.json`, "utf-8"));

// DB 전수 로드
const allBooks = [];
let from = 0;
const pageSize = 1000;
while (true) {
  const { data, error } = await sb
    .from("books")
    .select("id, title, option, status, price, condition_grade, shipments(seller_name)")
    .range(from, from + pageSize - 1);
  if (error) { console.error(error); process.exit(1); }
  if (!data || data.length === 0) break;
  allBooks.push(...data);
  if (data.length < pageSize) break;
  from += pageSize;
}

// 빈 행 제외
const excelValid = excel.filter((e) => e.title && String(e.title).trim() !== "");
console.log(`Excel rows (total): ${excel.length}`);
console.log(`Excel rows (with title): ${excelValid.length}`);
console.log(`DB books: ${allBooks.length}`);

// 정규화된 매칭 키로 카운트맵 생성
const excelKeyCount = new Map();
for (const e of excelValid) {
  const k = key(e.seller, e.title, e.option);
  excelKeyCount.set(k, (excelKeyCount.get(k) ?? 0) + 1);
}

const dbKeyCount = new Map();
const dbKeyBooks = new Map();
for (const b of allBooks) {
  const k = key(b.shipments?.seller_name, b.title, b.option);
  dbKeyCount.set(k, (dbKeyCount.get(k) ?? 0) + 1);
  if (!dbKeyBooks.has(k)) dbKeyBooks.set(k, []);
  dbKeyBooks.get(k).push(b);
}

// 검증: 엑셀에 N개 있으면 DB에 N개 이상 있어야 함
let totalExcel = 0;
let coveredExcel = 0;
const missing = [];
for (const [k, count] of excelKeyCount.entries()) {
  totalExcel += count;
  const dbCount = dbKeyCount.get(k) ?? 0;
  if (dbCount >= count) {
    coveredExcel += count;
  } else {
    coveredExcel += dbCount;
    const [seller, title, option] = k.split("|");
    missing.push({ seller, title, option, excel_count: count, db_count: dbCount, shortage: count - dbCount });
  }
}

console.log("\n=== 엑셀 커버리지 검증 ===");
console.log(`엑셀 총 권수:           ${totalExcel}`);
console.log(`DB에 매칭된 권수:      ${coveredExcel}`);
console.log(`DB 부족분 (실제 누락):  ${totalExcel - coveredExcel}`);

if (missing.length === 0) {
  console.log("\n✓ 엑셀의 모든 책이 DB에 등록됨!");
} else {
  console.log("\n=== 누락된 항목 ===");
  console.log(JSON.stringify(missing, null, 2));
}

// DB only — 엑셀에 없는데 DB에 있는 책 (정상: 이미 settled / 또는 누락 가능성)
console.log("\n=== DB에는 있는데 엑셀엔 없는 책 ===");
let dbOnlyCount = 0;
const dbOnlyByStatus = {};
const dbOnlyBySeller = {};
for (const [k, dbCount] of dbKeyCount.entries()) {
  const exCount = excelKeyCount.get(k) ?? 0;
  if (dbCount > exCount) {
    const extra = dbCount - exCount;
    dbOnlyCount += extra;
    // 어떤 status / seller인지 분포
    const books = dbKeyBooks.get(k).slice(0, extra);
    for (const b of books) {
      dbOnlyByStatus[b.status] = (dbOnlyByStatus[b.status] ?? 0) + 1;
      const s = b.shipments?.seller_name ?? "(none)";
      dbOnlyBySeller[s] = (dbOnlyBySeller[s] ?? 0) + 1;
    }
  }
}
console.log(`Total: ${dbOnlyCount}`);
console.log("By status:");
Object.entries(dbOnlyByStatus).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${k}: ${v}`));
console.log("By seller (top 15):");
Object.entries(dbOnlyBySeller).sort((a, b) => b[1] - a[1]).slice(0, 15).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

// 전체 status 분포
const statusDist = {};
for (const b of allBooks) statusDist[b.status] = (statusDist[b.status] ?? 0) + 1;
console.log("\n=== DB 전체 status 분포 ===");
Object.entries(statusDist).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${k}: ${v}`));
