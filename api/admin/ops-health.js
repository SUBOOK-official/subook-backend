import { createClient } from "@supabase/supabase-js";

/**
 * 자동화 헬스 리포트 Cron — 매일 00:00 UTC(09:00 KST) 실행.
 *
 * DB의 ops_cron_health_report() RPC를 호출한다. RPC가 pg_cron 잡 4종의 최근 성공 여부,
 * 구글시트 아웃박스 failed/정체, 알림톡 실패(24h)를 점검해 슬랙으로 요약을 발송한다.
 *
 * 트리거를 Vercel 크론에 둔 이유: pg_cron 자체가 죽거나(8/1 사고) 잡이 미등록돼도(8/13 발견)
 * 이 경로는 살아 있어 감지 가능 — 데드맨 스위치. 정상일 때도 슬랙에 한 줄이 오므로
 * "아침 리포트가 안 오면 그 자체가 장애 신호"다.
 */
export default async function handler(req, res) {
  // ⚠️ fail-close: CRON_SECRET 미설정이면 항상 차단
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

  // service_role은 VITE_* fallback 금지 (client 번들 embed 위험)
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
    const { data, error } = await supabase.rpc("ops_cron_health_report");

    if (error) {
      console.error("Ops health report error:", error.message);
      return res.status(500).json({ error: error.message });
    }

    console.log("Ops health report result:", JSON.stringify(data));
    return res.status(200).json(data);
  } catch (err) {
    console.error("Ops health report unexpected error:", err);
    return res.status(500).json({ error: "Internal server error" });
  }
}
