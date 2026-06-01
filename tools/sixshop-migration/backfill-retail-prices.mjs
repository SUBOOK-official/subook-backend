// 식스샵 상품 엑셀의 정가(G열) → books.original_price 백필.
//
// 배경: public 사이트는 books.original_price(정가)와 price(판매가)로 할인율을 계산해
//   "60% 15,600원 ~~39,000원~~"처럼 표시한다(스토어 RPC + ProductCard 이미 구현됨).
//   그러나 재고 적용 시 original_price를 안 넣어 정가가 비어 있어 할인이 안 떴다.
//   식스샵 상품 엑셀에는 정가(G)/판매가(J)가 구분돼 있어, 정가>판매가인 시중 상품의
//   정가를 가져와 백필한다. (정가==판매가인 비매품/자체산정 책은 대상 아님)
//
// 사용법:
//   set -a; source .env; source .env.local; set +a
//   # 1) xlsx에서 sheet1.xml 추출 후 경로 전달
//   node backfill-retail-prices.mjs <sheet1.xml-path>            # dry-run (기본, 쓰기 없음)
//   node backfill-retail-prices.mjs <sheet1.xml-path> --apply    # 실제 적용
//
// 매칭: 엑셀 제목(B) ↔ products.title  (정규화: trim + 공백축약 + lowercase)
//   매칭된 product의 books 중 "정가 > book.price"인 책에만 original_price=정가 설정.
//   이미 같은 값이면 스킵(idempotent). 정가<=판매가면 할인이 0/음수라 건드리지 않음.

import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

const sheetPath = process.argv[2];
const APPLY = process.argv.includes("--apply");
if (!sheetPath) {
  console.error("Usage: node backfill-retail-prices.mjs <sheet1.xml-path> [--apply]");
  process.exit(1);
}

const URL = process.env.VITE_SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!URL || !KEY) {
  console.error("env 누락: VITE_SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (set -a; source .env; source .env.local; set +a)");
  process.exit(1);
}
const sb = createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

// ── xlsx sheet1.xml 파싱 (parse-products.mjs와 동일 방식) ──
const decodeXml = (s) =>
  s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&apos;/g, "'");

function parseSheet(text) {
  const rows = [];
  const rowRe = /<row r="(\d+)"[^>]*>([\s\S]*?)<\/row>/g;
  const cellRe = /<c r="([A-Z]+)\d+"[^>]*?>(?:<v>([^<]*)<\/v>)?<\/c>/g;
  let m;
  while ((m = rowRe.exec(text)) !== null) {
    const inner = m[2];
    const cells = {};
    let cm;
    while ((cm = cellRe.exec(inner)) !== null) cells[cm[1]] = decodeXml(cm[2] ?? "");
    rows.push({ rowNum: parseInt(m[1], 10), cells });
  }
  return rows;
}

const toInt = (s) => {
  if (s == null || s === "") return null;
  const cleaned = String(s).replace(/[^0-9-]/g, "");
  if (!cleaned) return null;
  const n = parseInt(cleaned, 10);
  return Number.isFinite(n) ? n : null;
};

const norm = (s) => String(s ?? "").trim().replace(/\s+/g, " ").toLowerCase();

const rows = parseSheet(readFileSync(sheetPath, "utf-8")).filter((r) => r.rowNum > 1);

// 정가>판매가 타깃: norm(title) -> 정가 (충돌 시 최댓값 채택 + 로그)
const targetMap = new Map();
const conflicts = [];
for (const r of rows) {
  const title = (r.cells.B ?? "").trim();
  const retail = toInt(r.cells.G);
  const price = toInt(r.cells.J);
  if (!title || retail == null || price == null || retail <= price) continue;
  const k = norm(title);
  if (targetMap.has(k)) {
    const prev = targetMap.get(k);
    if (prev.retail !== retail) {
      conflicts.push({ title, prev: prev.retail, next: retail });
      if (retail > prev.retail) targetMap.set(k, { retail, title });
    }
  } else {
    targetMap.set(k, { retail, title });
  }
}

async function fetchAll(table, cols) {
  const all = [];
  let from = 0;
  const size = 1000;
  for (;;) {
    const { data, error } = await sb.from(table).select(cols).range(from, from + size - 1);
    if (error) throw error;
    all.push(...data);
    if (data.length < size) break;
    from += size;
  }
  return all;
}

const products = await fetchAll("products", "id,title");
const books = await fetchAll("books", "id,product_id,title,original_price,price,is_public,status");

const prodByNorm = new Map();
for (const p of products) {
  const k = norm(p.title);
  if (!prodByNorm.has(k)) prodByNorm.set(k, []);
  prodByNorm.get(k).push(p);
}

// 매칭된 product → 정가
const retailByProductId = new Map();
const matchedTitles = new Set();
const unmatchedTitles = [];
for (const [k, v] of targetMap) {
  const ps = prodByNorm.get(k);
  if (ps?.length) {
    matchedTitles.add(k);
    for (const p of ps) retailByProductId.set(p.id, v.retail);
  } else {
    unmatchedTitles.push(v.title);
  }
}

// 갱신 대상 book 계산: 정가 > price 이고 현재 값과 다른 책만
const updates = []; // { id, retail, price, title, is_public, status }
let skipRetailLePrice = 0;
let skipAlreadySet = 0;
for (const b of books) {
  if (b.product_id == null) continue;
  const retail = retailByProductId.get(b.product_id);
  if (retail == null) continue;
  const price = b.price ?? null;
  if (price == null || retail <= price) {
    skipRetailLePrice += 1;
    continue;
  }
  if (b.original_price === retail) {
    skipAlreadySet += 1;
    continue;
  }
  updates.push({ id: b.id, retail, price, title: b.title, is_public: b.is_public, status: b.status });
}

// ── 리포트 ──
console.log("=== 타깃(정가>판매가) ===");
console.log(`고유 제목: ${targetMap.size} | 매칭: ${matchedTitles.size} | 미매칭: ${unmatchedTitles.length} | 충돌(최댓값채택): ${conflicts.length}`);
console.log("\n=== 갱신 대상 books ===");
console.log(`UPDATE 예정: ${updates.length}권 (public ${updates.filter((u) => u.is_public).length}, on_sale ${updates.filter((u) => u.status === "on_sale").length})`);
console.log(`스킵 - 정가<=판매가: ${skipRetailLePrice} | 이미 동일값: ${skipAlreadySet}`);

const byRetail = new Map();
for (const u of updates) byRetail.set(u.retail, (byRetail.get(u.retail) ?? 0) + 1);
console.log(`\n정가 값 분포(고유 ${byRetail.size}종):`,
  [...byRetail.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([v, n]) => `${v.toLocaleString()}원×${n}`).join(", "));

console.log("\n=== 샘플 15 ===");
for (const u of updates.slice(0, 15)) {
  const pct = Math.round(((u.retail - u.price) / u.retail) * 100);
  console.log(`  ${u.title?.slice(0, 42)} | 판매 ${u.price.toLocaleString()} ← 정가 ${u.retail.toLocaleString()} (${pct}%)`);
}
if (unmatchedTitles.length) {
  console.log(`\n미매칭 제목(${unmatchedTitles.length}):`);
  unmatchedTitles.forEach((t) => console.log("  - " + t));
}
if (conflicts.length) {
  console.log(`\n정가 충돌(최댓값 채택):`);
  conflicts.forEach((c) => console.log(`  ${c.title}: ${c.prev} ↔ ${c.next}`));
}

if (!APPLY) {
  console.log("\n[dry-run] 쓰기 안 함. 실제 적용하려면 --apply 추가.");
  process.exit(0);
}

// ── --apply: 정가 값별로 묶어 배치 UPDATE ──
console.log("\n>>> 적용 중...");
const idsByRetail = new Map();
for (const u of updates) {
  if (!idsByRetail.has(u.retail)) idsByRetail.set(u.retail, []);
  idsByRetail.get(u.retail).push(u.id);
}
let done = 0;
for (const [retail, ids] of idsByRetail) {
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const { error } = await sb.from("books").update({ original_price: retail }).in("id", chunk);
    if (error) {
      console.error(`정가 ${retail} 청크 실패:`, error.message ?? error);
      process.exit(1);
    }
    done += chunk.length;
  }
}
console.log(`완료: ${done}권 갱신.`);
