// 식스샵 상품 일괄 INSERT to Supabase products 테이블.
// 입력: output/products-with-new-images.json (migrate-images.mjs 결과)
//       또는 output/products-mapped.json (이미지 이관 안 했을 때)
// service_role 키로 admin_bulk_upsert_products_sixshop RPC 호출.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SUPABASE_URL = process.env.VITE_SUPABASE_URL || `https://${process.env.SUPABASE_PROJECT_REF}.supabase.co`;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env. Run: set -a; source .env.local; set +a");
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const inputFile = process.argv[2] || resolve(`${__dirname}/output/products-with-new-images.json`);
const rawProducts = JSON.parse(readFileSync(inputFile, "utf-8"));
console.log(`Loaded ${rawProducts.length} products from ${inputFile}`);

// dedup: 같은 메타데이터를 가진 행은 group_key가 동일하므로 한 번만 INSERT
// (storefront_product_group_key SQL 함수와 동일한 키 정의)
function dedupKey(p) {
  return [
    (p.title || "").trim().toLowerCase(),
    (p.option || "").trim().toLowerCase(),
    (p.subject || "").trim().toLowerCase(),
    (p.brand || "").trim().toLowerCase(),
    (p.book_type || "").trim().toLowerCase(),
    p.published_year ?? "",
    (p.instructor_name || "").trim().toLowerCase(),
  ].join("|");
}

const seen = new Set();
const products = [];
let dupCount = 0;
for (const p of rawProducts) {
  const k = dedupKey(p);
  if (seen.has(k)) {
    dupCount += 1;
    continue;
  }
  seen.add(k);
  products.push(p);
}
console.log(`After dedup: ${products.length} unique (${dupCount} duplicates removed)`);

const BATCH_SIZE = 100;
let totalInserted = 0;
let totalUpdated = 0;

for (let i = 0; i < products.length; i += BATCH_SIZE) {
  const batch = products.slice(i, i + BATCH_SIZE).map((p) => ({
    title: p.title,
    option: p.option,
    subject: p.subject,
    brand: p.brand,
    book_type: p.book_type,
    published_year: p.published_year,
    instructor_name: p.instructor_name,
    cover_image_url: p.cover_image_url,
    status: p.status,
  }));

  const { data, error } = await supabase.rpc("admin_bulk_upsert_products_sixshop", {
    p_payload: batch,
  });

  if (error) {
    console.error(`Batch ${Math.floor(i / BATCH_SIZE) + 1} failed:`, error.message ?? error);
    process.exit(1);
  }

  totalInserted += data?.inserted ?? 0;
  totalUpdated += data?.updated ?? 0;
  console.log(
    `  [${Math.min(i + BATCH_SIZE, products.length)}/${products.length}] inserted=${totalInserted} updated=${totalUpdated}`,
  );
}

console.log(`\nDone. Total: inserted=${totalInserted}, updated=${totalUpdated}`);
