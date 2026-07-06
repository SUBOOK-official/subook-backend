import { createClient } from "@supabase/supabase-js";

/**
 * 배송완료 D+7 자동 구매확정 Cron
 * 매일 오전 10시(KST) 실행 — auto_confirm_at <= now() 인 delivered 주문을 자동 확정
 * + 셀러 'sold' 알림 자동 발송 (CRON_SECRET으로 send-notification 호출)
 */

async function notifySellerSold({ baseUrl, cronSecret, seller }) {
  // 동일 핸들러 도메인의 send-notification을 CRON_SECRET 인증으로 호출
  const url = `${baseUrl}/api/admin/send-notification`;
  const body = {
    notificationType: "sold",
    recipientPhone: seller.seller_phone,
    recipientName: seller.seller_name,
    recipientUserId: seller.seller_user_id,
    refType: "order",
    refId: seller.order_id,
    templateVariables: {
      bookTitle: seller.book_title,
      settlementDate: seller.settlement_date,
    },
  };

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cronSecret}`,
      },
      body: JSON.stringify(body),
    });
    return { ok: response.ok, status: response.status };
  } catch (err) {
    console.error("notifySellerSold fetch failed:", err.message);
    return { ok: false, status: 0 };
  }
}

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

    // 셀러별 'sold' 알림 발송 (실패해도 confirmed 자체는 유지)
    const sellers = Array.isArray(data?.sellers_to_notify) ? data.sellers_to_notify : [];
    let notifySent = 0;
    let notifyFailed = 0;
    if (sellers.length > 0) {
      const protocol = req.headers["x-forwarded-proto"] || "https";
      const host = req.headers["x-forwarded-host"] || req.headers.host;
      const baseUrl = `${protocol}://${host}`;
      const results = await Promise.allSettled(
        sellers.map((seller) => notifySellerSold({ baseUrl, cronSecret, seller })),
      );
      for (const r of results) {
        if (r.status === "fulfilled" && r.value.ok) notifySent += 1;
        else notifyFailed += 1;
      }
    }

    return res.status(200).json({
      ...data,
      notifications_sent: notifySent,
      notifications_failed: notifyFailed,
    });
  } catch (err) {
    console.error("Auto-confirm unexpected error:", err);
    return res.status(500).json({ error: "Internal server error" });
  }
}
