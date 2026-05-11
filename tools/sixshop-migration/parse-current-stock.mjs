// 실제 창고 현재 재고 xlsx 파싱.
// 입력: xl/sharedStrings.xml + xl/worksheets/sheet1.xml 추출된 경로
// 출력: output/current-stock.json + 통계
//
// 컬럼: 일련번호 / 위치 / 수거신청자 / 상품명 / 판매가 / 옵션 / 필기율 / 판매완료여부

import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const xlsxDir = process.argv[2];
if (!xlsxDir) {
  console.error("Usage: node parse-current-stock.mjs <path-to-extracted-xlsx-dir>");
  process.exit(1);
}
const outDir = resolve(`${__dirname}/output`);
mkdirSync(outDir, { recursive: true });

function decodeXml(s) {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

// sharedStrings.xml → index → text 배열
function parseSharedStrings(xml) {
  const out = [];
  // <si>...<t>text</t>...</si>  (단일 또는 다중 <t>도 가능 — rich text)
  const siRe = /<si\b[^>]*>([\s\S]*?)<\/si>/g;
  const tRe = /<t[^>]*>([\s\S]*?)<\/t>/g;
  let m;
  while ((m = siRe.exec(xml)) !== null) {
    let parts = [];
    let tm;
    tRe.lastIndex = 0;
    while ((tm = tRe.exec(m[1])) !== null) parts.push(tm[1]);
    out.push(decodeXml(parts.join("")));
  }
  return out;
}

// sheet1.xml → rows[i].cells[colLetter] = value
function parseSheet(xml, shared) {
  const rows = [];
  const rowRe = /<row r="(\d+)"[^>]*>([\s\S]*?)<\/row>/g;
  // <c r="A1" t="s"><v>5</v></c>  /  <c r="A1"><v>123</v></c>  /  <c r="A1" t="str"><v>...</v></c>
  // formula도 있을 수 있음: <c r="A1" t="str"><f>...</f><v>cached</v></c>
  const cellRe = /<c r="([A-Z]+)\d+"([^>]*)>(?:<f[^>]*>[\s\S]*?<\/f>)?(?:<v>([^<]*)<\/v>)?<\/c>/g;
  let m;
  while ((m = rowRe.exec(xml)) !== null) {
    const rowNum = parseInt(m[1], 10);
    const inner = m[2];
    const cells = {};
    let cm;
    cellRe.lastIndex = 0;
    while ((cm = cellRe.exec(inner)) !== null) {
      const col = cm[1];
      const attrs = cm[2] || "";
      const raw = cm[3] ?? "";
      const isShared = / t="s"/.test(attrs);
      const isInlineStr = / t="str"/.test(attrs);
      let value = "";
      if (raw === "") value = "";
      else if (isShared) value = shared[parseInt(raw, 10)] ?? "";
      else if (isInlineStr) value = decodeXml(raw);
      else value = raw; // number or other
      cells[col] = value;
    }
    rows.push({ rowNum, cells });
  }
  return rows;
}

const sharedXml = readFileSync(`${xlsxDir}/xl/sharedStrings.xml`, "utf-8");
const sheetXml = readFileSync(`${xlsxDir}/xl/worksheets/sheet1.xml`, "utf-8");
const shared = parseSharedStrings(sharedXml);
const rows = parseSheet(sheetXml, shared);

console.log(`Shared strings: ${shared.length}`);
console.log(`Total rows: ${rows.length}`);

const data = [];
for (const row of rows) {
  if (row.rowNum === 1) continue; // header
  const c = row.cells;
  const serial = c.A?.trim();
  const location = c.B?.trim();
  const seller = c.C?.trim();
  const title = c.D?.trim();
  const price = c.E ? parseInt(c.E, 10) : null;
  const option = c.F?.trim();
  const writingPct = c.G?.trim();
  const soldFlag = c.H?.trim();

  // 완전히 빈 행 skip
  if (!serial && !seller && !title && !option) continue;
  data.push({ serial, location, seller, title, price, option, writingPct, soldFlag });
}

console.log(`Data rows (non-empty): ${data.length}`);

// 통계
const sellerCounts = {};
const titleCounts = {};
const soldCounts = {};
const locationCounts = {};
for (const d of data) {
  if (d.seller) sellerCounts[d.seller] = (sellerCounts[d.seller] ?? 0) + 1;
  if (d.title) titleCounts[d.title] = (titleCounts[d.title] ?? 0) + 1;
  soldCounts[d.soldFlag || "(empty)"] = (soldCounts[d.soldFlag || "(empty)"] ?? 0) + 1;
  if (d.location) locationCounts[d.location.split(/\d/)[0] || d.location] = (locationCounts[d.location.split(/\d/)[0] || d.location] ?? 0) + 1;
}

writeFileSync(`${outDir}/current-stock.json`, JSON.stringify(data, null, 2));
writeFileSync(`${outDir}/current-stock-stats.json`, JSON.stringify({
  total_rows: data.length,
  by_seller: sellerCounts,
  by_sold_flag: soldCounts,
  unique_titles: Object.keys(titleCounts).length,
  by_location_prefix: locationCounts,
}, null, 2));

console.log("\n=== 셀러별 권수 ===");
Object.entries(sellerCounts).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => {
  console.log(`  ${k}: ${v}`);
});

console.log("\n=== 판매완료여부 분포 ===");
Object.entries(soldCounts).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => {
  console.log(`  '${k}': ${v}`);
});

console.log(`\nUnique titles: ${Object.keys(titleCounts).length}`);
console.log(`Output: ${outDir}/current-stock.json`);
