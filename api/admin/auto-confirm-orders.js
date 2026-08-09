import { createClient } from "@supabase/supabase-js";

/**
 * 배송완료 D+7 자동 구매확정 Cron
 * 매시간 실행(2026-08-04 Pro 전환으로 일 1회→매시 상향) — auto_confirm_at <= now() 인
 * delivered 주문을 자동 확정. 확정 시점이 D+7에 최대 1시간 오차로 근접.
 * (2026-08-09 템플릿 v2: 셀러 'sold' 판매완료 알림톡 폐지 — RPC가 반환하는
 *  sellers_to_notify는 무시하고 확정 처리만 수행한다.)
 */

export default async function handler(req, res) {
  // ⚠️ Cron 요청 검증 (fail-close): CRON_SECRET 미설정이면 항상 401.
  // env 빠뜨려서 endpoint가 무인증 공개되는 사고 방지.
  const authHeader = req.headers.authorization;
  const cronSecret = process.env.CRON_SECRET;

  if (!cronSecret) {
    console.error("CRON_SECRET env not configured");
    return res.status(500).json({ error: "Server misconfigured" });
  }
  if (authHeader !== `Bearer ${cronSecret}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  // GET만 허용 (Vercel Cron은 GET 요청)
  if (req.method !== "GET") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  // ⚠️ service_role은 VITE_* fallback 금지. VITE_* prefix는 client 번들에 embed되므로
  // 누군가 실수로 그 이름에 service_role을 등록하면 키가 공개됨.
  const supabaseUrl =
    process.env.SUPABASE_URL ||
    process.env.SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_URL;
  const supabaseServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;

  if (!supabaseUrl || !supabaseServiceKey) {
    return res.status(500).json({ error: "Missing Supabase configuration" });
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const { data, error } = await supabase.rpc("auto_confirm_delivered_orders");

    if (error) {
      console.error("Auto-confirm error:", error.message);
      return res.status(500).json({ error: error.message });
    }

    console.log("Auto-confirm result:", JSON.stringify(data));

    return res.status(200).json(data);
  } catch (err) {
    console.error("Auto-confirm unexpected error:", err);
    return res.status(500).json({ error: "Internal server error" });
  }
}
