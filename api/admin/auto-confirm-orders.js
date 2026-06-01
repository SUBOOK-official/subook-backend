import { createClient } from "@supabase/supabase-js";

/**
 * 배송완료 D+7 자동 구매확정 Cron
 * 매일 오전 10시(KST) 실행 — auto_confirm_at <= now() 인 delivered 주문을 자동 확정
 */
export default async function handler(req, res) {
  // Cron 요청 검증 (Vercel Cron은 Authorization 헤더로 CRON_SECRET 전송)
  const authHeader = req.headers.authorization;
  const cronSecret = process.env.CRON_SECRET;

  if (!cronSecret) {
    console.error("CRON_SECRET env not configured");
    return res.status(500).json({ error: "Server misconfigured" });
  }
  if (authHeader !== `Bearer ${cronSecret}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  if (req.method !== "GET") {
    return res.status(405).json({ error: "Method not allowed" });
  }

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
