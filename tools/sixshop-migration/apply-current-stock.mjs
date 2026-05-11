// 현재 창고 재고 엑셀 기반으로 DB books를 일괄 보정.
//
// 입력:
//   - output/in_excel_only.json — 엑셀에만 있는 (= 새로 INSERT 필요한) 책
//   - output/matched.json       — excel ↔ db 매칭 (excel.soldFlag === '판매완료'인건 settled로)
//   - output/in_db_only.json    — DB에만 있는 (엑셀에 없는 = 품절 처리할) 책
//
// 정책:
//   - seller "1" → "정희원"
//   - seller "매입" (or null) → 가상 shipment '수북 자체 매입'
//   - writingPct "A+(필기율 X%)" 패턴: condition_grade A_PLUS + writing_pct=X
//   - DB only인데 status='on_sale'인 것만 sold_out 처리 (이미 settled/sold_out인건 그대로)
//
// 결과는 RPC가 jsonb로 리턴.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(`${__dirname}/output`);

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || `https://${process.env.SUPABASE_PROJECT_REF}.supabase.co`;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SERVICE_KEY) {
  console.error("SUPABASE_SERVICE_ROLE_KEY missing");
  process.exit(1);
}
const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// ---- 헬퍼 ----
function normalizeSeller(name) {
  if (name == null) return null;
  const t = String(name).trim();
  if (t === "" || t === "매입") return t;
  if (t === "1") return "정희원"; // 사용자 지정 매핑
  return t;
}

// "A+(필기율 1%)" → { grade: 'A_PLUS', pct: 1 }
// "A+(뒷표지 주름)" → { grade: 'A_PLUS', pct: null }
// "펼쳐서 필기율 확인하기" / "식스샵 등록X" / null → { grade: null, pct: null }
function parseWritingPctText(text) {
  if (!text) return { grade: null, pct: null };
  const s = String(text).trim();
  let grade = null;
  if (/A\+/.test(s)) grade = "A_PLUS";
  else if (/(^|\s|-)A([^A-Za-z+]|$)/.test(s)) grade = "A";
  // 필기율 N%
  const pctMatch = s.match(/필기율\s*(\d+)\s*%/);
  const pct = pctMatch ? parseInt(pctMatch[1], 10) : null;
  return { grade, pct };
}

// 옵션 텍스트에서 추가로 등급 추출 (writingPct 결과로 보강 못 한 경우)
function gradeFromOption(option) {
  if (!option) return null;
  const s = String(option);
  if (/A\+/.test(s)) return "A_PLUS";
  if (/(^|\s|-)A([^A-Za-z+]|$)/.test(s)) return "A";
  return null;
}

// ---- 로드 ----
const inExcelOnly = JSON.parse(readFileSync(`${outDir}/in_excel_only.json`, "utf-8"));
const matched = JSON.parse(readFileSync(`${outDir}/matched.json`, "utf-8"));
const inDbOnly = JSON.parse(readFileSync(`${outDir}/in_db_only.json`, "utf-8"));

console.log(`Loaded: excel_only=${inExcelOnly.length}, matched=${matched.length}, db_only=${inDbOnly.length}`);

// ---- new_books payload ----
const newBooks = inExcelOnly.map((e) => {
  const seller = normalizeSeller(e.seller);
  const { grade: gradeFromWP, pct } = parseWritingPctText(e.writingPct);
  const grade = gradeFromWP || gradeFromOption(e.option) || "S";
  return {
    seller: seller, // null/"매입" → 가상 shipment
    title: e.title || "",
    option: e.option || "",
    price: e.price != null ? Number(e.price) : null,
    writing_pct: pct != null ? pct : "",
    sold_flag: e.soldFlag || "",
    condition_grade: grade,
  };
});

// ---- settled_ids: matched 중 excel.soldFlag === '판매완료' ----
const settledIds = matched
  .filter((m) => m.excel?.soldFlag === "판매완료")
  .map((m) => m.db.id);

// ---- sold_out_ids: DB에만 있는 것 중 status='on_sale'만 ----
//   (이미 settled/sold_out인건 그대로 두고 = idempotent)
const soldOutIds = inDbOnly
  .filter((b) => b.status === "on_sale")
  .map((b) => b.id);

console.log("\n=== Payload summary ===");
console.log(`  new_books:    ${newBooks.length}`);
console.log(`  settled_ids:  ${settledIds.length}`);
console.log(`  sold_out_ids: ${soldOutIds.length}`);

// ---- 셀러 분포 미리보기 ----
const sellerDist = {};
for (const b of newBooks) sellerDist[b.seller || "(매입/null)"] = (sellerDist[b.seller || "(매입/null)"] ?? 0) + 1;
console.log("\n=== new_books — by seller ===");
Object.entries(sellerDist).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

const gradeDist = {};
for (const b of newBooks) gradeDist[b.condition_grade] = (gradeDist[b.condition_grade] ?? 0) + 1;
console.log("\n=== new_books — by grade ===");
Object.entries(gradeDist).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => console.log(`  ${k}: ${v}`));

// ---- DRY-RUN: --apply 플래그 있을 때만 RPC 호출 ----
const apply = process.argv.includes("--apply");
if (!apply) {
  console.log("\n[dry-run] --apply 플래그를 추가하면 실제로 RPC 호출됩니다.");
  console.log("Sample new_books[0]:", JSON.stringify(newBooks[0], null, 2));
  console.log("Sample new_books[100]:", JSON.stringify(newBooks[100], null, 2));
  process.exit(0);
}

// ---- 실제 호출 ----
console.log("\n>>> RPC 호출 중...");
const { data, error } = await sb.rpc("admin_apply_current_stock_diff", {
  p_payload: {
    purchasing_seller_name: "수북 자체 매입",
    new_books: newBooks,
    settled_ids: settledIds,
    sold_out_ids: soldOutIds,
  },
});

if (error) {
  console.error("ERROR:", error);
  process.exit(1);
}

console.log("\n=== RESULT ===");
console.log(JSON.stringify(data, null, 2));
