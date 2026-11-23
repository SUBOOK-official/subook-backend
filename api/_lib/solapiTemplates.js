// 알림톡 타입 → 솔라피 templateId 매핑. 템플릿 검수 통과 후 SOLAPI_TEMPLATE_IDS(JSON)로 주입.
//   예) SOLAPI_TEMPLATE_IDS={"pickup_accepted":"KA01TP...","arrived":"KA01TP...",...}
// 새 타입은 공용 JSON env를 건드리지 않도록 코드 기본값을 둔다(templateId는 비밀값 아님, env에 같은 키가 있으면 env 우선).
import { createHmac, randomBytes } from "crypto";

const SOLAPI_TEMPLATE_URL = "https://api.solapi.com/kakao/v2/templates/";
const TEMPLATE_STATUSES = new Set(["PENDING", "INSPECTING", "APPROVED", "REJECTED"]);

export const DEFAULT_SOLAPI_TEMPLATE_IDS = {
  // 수북 일성월심 앱안내 v1 — 2026-11-18 솔라피 등록·카카오 검수 요청(ALIMTALK_TEMPLATES.md "일성월심 앱 이용 안내" 절)
  app_guide: "KA01TP2611181230053048VITk7GCMRa",
};

export function getSolapiTemplateId(notificationType, env = process.env) {
  let map = {};
  try {
    map = JSON.parse(env.SOLAPI_TEMPLATE_IDS || "{}") || {};
  } catch {
    map = {};
  }
  return map[notificationType] || DEFAULT_SOLAPI_TEMPLATE_IDS[notificationType] || "";
}

/**
 * 알림톡 템플릿의 카카오 검수 상태를 솔라피에 묻는다.
 * @returns {Promise<"APPROVED"|"INSPECTING"|"PENDING"|"REJECTED"|"UNKNOWN">} UNKNOWN = 확인하지 못함(설정 없음·연결 실패·모르는 답)
 */
export async function fetchSolapiTemplateStatus(templateId, { env = process.env, fetchImpl = globalThis.fetch, timeoutMs = 4000 } = {}) {
  const apiKey = env.SOLAPI_API_KEY;
  const apiSecret = env.SOLAPI_API_SECRET;
  if (!templateId || !apiKey || !apiSecret) return "UNKNOWN";
  const date = new Date().toISOString();
  const salt = randomBytes(32).toString("hex");
  const signature = createHmac("sha256", apiSecret).update(date + salt).digest("hex");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(SOLAPI_TEMPLATE_URL + encodeURIComponent(templateId), {
      headers: { Authorization: `HMAC-SHA256 apiKey=${apiKey}, date=${date}, salt=${salt}, signature=${signature}` },
      signal: controller.signal,
    });
    if (!response.ok) return "UNKNOWN";
    const data = await response.json().catch(() => null);
    const status = String(data?.status || "").toUpperCase();
    return TEMPLATE_STATUSES.has(status) ? status : "UNKNOWN";
  } catch {
    return "UNKNOWN";
  } finally {
    clearTimeout(timer);
  }
}
