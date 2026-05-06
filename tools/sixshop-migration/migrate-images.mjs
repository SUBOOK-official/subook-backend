// 식스샵 CDN 이미지 → Supabase Storage 이관.
// 입력: output/products-mapped.json (parse-products.mjs 결과)
// 출력: output/products-with-new-images.json (cover_image_url 갱신)
//       output/image-migration-log.json (성공/실패 로그)
//
// 사용법:
//   set -a; source .env.local; set +a
//   node backend/tools/sixshop-migration/migrate-images.mjs

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(`${__dirname}/output`);
mkdirSync(outDir, { recursive: true });

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || `https://${process.env.SUPABASE_PROJECT_REF}.supabase.co`;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env. Run: set -a; source .env.local; set +a");
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const BUCKET = "product-covers";
const PROGRESS_PATH = `${outDir}/image-migration-progress.json`;
const LOG_PATH = `${outDir}/image-migration-log.json`;

// 이전 실행 진행률 로드 (resume 지원)
let progress = { processed: {}, started_at: null, last_index: 0 };
try {
  progress = JSON.parse(readFileSync(PROGRESS_PATH, "utf-8"));
  console.log(`Resuming from index ${progress.last_index}, ${Object.keys(progress.processed).length} already done`);
} catch {
  progress.started_at = new Date().toISOString();
}

function saveProgress() {
  writeFileSync(PROGRESS_PATH, JSON.stringify(progress, null, 2));
}

function inferContentType(url) {
  const lower = url.toLowerCase();
  if (lower.includes(".png")) return "image/png";
  if (lower.includes(".webp")) return "image/webp";
  if (lower.includes(".gif")) return "image/gif";
  return "image/jpeg";
}

function inferExtension(url, contentType) {
  if (contentType === "image/png") return "png";
  if (contentType === "image/webp") return "webp";
  if (contentType === "image/gif") return "gif";
  return "jpg";
}

async function fetchImage(url) {
  const res = await fetch(url, { redirect: "follow" });
  if (!res.ok) throw new Error(`fetch ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const ct = res.headers.get("content-type") || inferContentType(url);
  return { buf, contentType: ct };
}

async function uploadImage(sixshopId, buf, contentType) {
  const ext = inferExtension("", contentType);
  const path = `sixshop/${sixshopId}.${ext}`;
  const { error } = await supabase.storage
    .from(BUCKET)
    .upload(path, buf, { contentType, upsert: true });
  if (error) throw error;
  const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
  return { path, url: pub.publicUrl };
}

const products = JSON.parse(readFileSync(`${outDir}/products-mapped.json`, "utf-8"));
console.log(`Loaded ${products.length} products`);

const log = { success: 0, failed: 0, skipped: 0, errors: [] };
const results = [];

for (let i = 0; i < products.length; i += 1) {
  const p = products[i];
  const key = p.sixshop_id || `idx_${i}`;

  // 이미 처리됨
  if (progress.processed[key]) {
    results.push({ ...p, cover_image_url: progress.processed[key] });
    log.skipped += 1;
    continue;
  }

  if (!p.cover_image_url) {
    results.push(p);
    log.skipped += 1;
    progress.processed[key] = null;
    continue;
  }

  const startMs = Date.now();
  try {
    const { buf, contentType } = await fetchImage(p.cover_image_url);
    const { url } = await uploadImage(key, buf, contentType);
    progress.processed[key] = url;
    progress.last_index = i;
    results.push({ ...p, cover_image_url: url, original_cover_image_url: p.cover_image_url });
    log.success += 1;

    if ((i + 1) % 20 === 0) {
      saveProgress();
      console.log(`  [${i + 1}/${products.length}] ok=${log.success} fail=${log.failed} skip=${log.skipped} (${Date.now() - startMs}ms)`);
    }
  } catch (err) {
    log.failed += 1;
    log.errors.push({ sixshop_id: key, title: p.title, url: p.cover_image_url, error: String(err) });
    results.push(p);  // 실패 시 원본 url 그대로 유지
    progress.processed[key] = null;
    console.warn(`  [${i + 1}/${products.length}] FAIL ${key}: ${err.message ?? err}`);
  }
}

saveProgress();
writeFileSync(`${outDir}/products-with-new-images.json`, JSON.stringify(results, null, 2));
writeFileSync(LOG_PATH, JSON.stringify(log, null, 2));

console.log("\n=== Done ===");
console.log(`Success: ${log.success}`);
console.log(`Failed:  ${log.failed}`);
console.log(`Skipped: ${log.skipped}`);
console.log(`Output:  ${outDir}/products-with-new-images.json`);
if (log.failed > 0) {
  console.log(`Errors:  ${LOG_PATH}`);
}
