// 출시 전 테스트 데이터 초기화 스크립트.
// 운영자(admin_users) 제외한 모든 auth.users + 관련 데이터 삭제.
//
// 사용법:
//   node backend/scripts/wipe-test-members.mjs --dry-run    # 카운트만 보기
//   node backend/scripts/wipe-test-members.mjs --confirm    # 실제 삭제
//
// .env.local 에서 SUPABASE_ADMIN_URL + SUPABASE_SERVICE_ROLE_KEY 사용.

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ENV_PATH = resolve(__dirname, "../../.env.local");

function loadEnv(path) {
  const lines = readFileSync(path, "utf8").split(/\r?\n/);
  const env = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    // 양쪽 따옴표 제거
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
  return env;
}

const env = loadEnv(ENV_PATH);
const projectRef = env.SUPABASE_PROJECT_REF;
const supabaseUrl =
  env.SUPABASE_ADMIN_URL ||
  env.VITE_SUPABASE_ADMIN_URL ||
  env.VITE_SUPABASE_PUBLIC_URL ||
  (projectRef ? `https://${projectRef}.supabase.co` : null);
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !serviceKey) {
  console.error("SUPABASE URL 또는 SUPABASE_SERVICE_ROLE_KEY 가 .env.local 에 필요합니다.");
  console.error(`  resolved url=${supabaseUrl}, has key=${!!serviceKey}, project_ref=${projectRef}`);
  process.exit(1);
}

const isDryRun = process.argv.includes("--dry-run");
const isConfirm = process.argv.includes("--confirm");

if (!isDryRun && !isConfirm) {
  console.error("--dry-run 또는 --confirm 를 명시해 주세요.");
  process.exit(1);
}

const supabase = createClient(supabaseUrl, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function listAllAuthUsers() {
  const all = [];
  let page = 1;
  const perPage = 1000;
  while (true) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage });
    if (error) throw error;
    const users = data?.users ?? [];
    all.push(...users);
    if (users.length < perPage) break;
    page += 1;
    if (page > 50) break; // 안전 한계
  }
  return all;
}

async function fetchAdminEmails() {
  const { data, error } = await supabase.from("admin_users").select("email");
  if (error) throw error;
  return new Set((data ?? []).map((row) => String(row.email || "").toLowerCase()));
}

async function fetchImpactCounts(targetUserIds) {
  if (targetUserIds.length === 0) return null;
  const sample = targetUserIds.slice(0, 1000); // 안전 한계 (.in() 길이 제한 회피)

  async function count(table, column) {
    const { count, error } = await supabase
      .from(table)
      .select("id", { count: "exact", head: true })
      .in(column, sample);
    if (error) return `(쿼리 실패: ${error.message})`;
    return count ?? 0;
  }

  return {
    member_profiles: await count("member_profiles", "user_id"),
    cart_items: await count("cart_items", "user_id"),
    orders: await count("orders", "user_id"),
    pickup_requests: await count("pickup_requests", "user_id"),
    wishlist_items: await count("wishlist_items", "user_id"),
    member_shipping_addresses: await count("member_shipping_addresses", "user_id"),
    member_settlement_accounts: await count("member_settlement_accounts", "user_id"),
    settlements_NULL_set: await count("settlements", "seller_user_id"),
  };
}

async function main() {
  console.log(`Supabase URL: ${supabaseUrl}`);
  console.log(`모드: ${isDryRun ? "DRY RUN (삭제 안 함)" : "CONFIRM (실제 삭제)"}`);
  console.log("-".repeat(60));

  const adminEmails = await fetchAdminEmails();
  console.log(`운영자(admin_users) 수: ${adminEmails.size}`);
  console.log(`운영자 이메일: ${Array.from(adminEmails).join(", ") || "(없음)"}`);

  const allUsers = await listAllAuthUsers();
  console.log(`전체 auth.users 수: ${allUsers.length}`);

  const targets = allUsers.filter((user) => {
    const email = String(user.email || "").toLowerCase();
    if (!email) return true; // 익명 가입자도 대상
    return !adminEmails.has(email);
  });

  console.log(`삭제 대상(운영자 제외) 수: ${targets.length}`);
  console.log("-".repeat(60));

  if (targets.length === 0) {
    console.log("삭제할 일반 사용자가 없습니다.");
    return;
  }

  const impact = await fetchImpactCounts(targets.map((u) => u.id));
  if (impact) {
    console.log("Cascade 영향 카운트(샘플 최대 1000명 기준):");
    for (const [k, v] of Object.entries(impact)) {
      console.log(`  ${k}: ${v}`);
    }
    console.log("-".repeat(60));
  }

  if (isDryRun) {
    console.log("DRY RUN 종료 — 실제 삭제는 --confirm 으로 재실행.");
    return;
  }

  console.log("실제 삭제 시작...");
  let success = 0;
  let failed = 0;
  for (let i = 0; i < targets.length; i += 1) {
    const user = targets[i];
    try {
      const { error } = await supabase.auth.admin.deleteUser(user.id);
      if (error) {
        failed += 1;
        console.error(`  [실패] ${user.email || user.id}: ${error.message}`);
      } else {
        success += 1;
        if ((i + 1) % 10 === 0 || i === targets.length - 1) {
          console.log(`  진행: ${i + 1}/${targets.length} (성공 ${success}, 실패 ${failed})`);
        }
      }
    } catch (caught) {
      failed += 1;
      console.error(`  [예외] ${user.email || user.id}: ${caught?.message || caught}`);
    }
  }
  console.log("-".repeat(60));
  console.log(`완료. 성공 ${success}건, 실패 ${failed}건.`);
}

main().catch((error) => {
  console.error("스크립트 실행 실패:", error);
  process.exit(1);
});
