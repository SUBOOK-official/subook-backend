// 직전 RPC가 atomic rollback 됐는지 확인
import { createClient } from "@supabase/supabase-js";
const sb = createClient(
  process.env.VITE_SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

// purchasing shipment 존재?
const { data: ship } = await sb
  .from("shipments")
  .select("id, seller_name")
  .eq("seller_name", "수북 자체 매입");
console.log("수북 자체 매입 shipment:", ship);

// 최신 books id
const { data: latest } = await sb
  .from("books")
  .select("id, title, shipment_id, status, condition_grade")
  .order("id", { ascending: false })
  .limit(3);
console.log("Latest books:", latest);

// 총 카운트
const { count } = await sb
  .from("books")
  .select("*", { count: "exact", head: true });
console.log("Total books:", count);

// status별
const statuses = ["on_sale", "settled", "sold_out"];
for (const s of statuses) {
  const { count: c } = await sb
    .from("books")
    .select("*", { count: "exact", head: true })
    .eq("status", s);
  console.log(`  ${s}: ${c}`);
}
