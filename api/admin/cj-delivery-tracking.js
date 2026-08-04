import { createClient } from "@supabase/supabase-js";

/**
 * 배송중 주문 자동 배송완료 Cron (2026-07-24)
 *
 * 매시간 실행(2026-08-04 Pro 전환으로 일 1회→매시 상향, Hobby 시절 일 1회 제한 해소)
 * — status='shipping'이고 운송장이 있는
 * 주문을 CJ 상품추적 API(ReqOneGdsTrc)로 조회해, 화물상태 91(배송완료)이면:
 *   1) orders.status → 'delivered' + auto_confirm_at = now()+7일
 *      (admin_update_order_status의 delivered 전이와 동일 — 그쪽 정책이 바뀌면 여기도 맞출 것)
 *   2) 구매자에게 delivery_done 알림톡 발송 (best-effort — 실패해도 전이는 유지)
 * 이후 D+7 자동 구매확정(auto-confirm-orders 크론)이 이어받는다.
 *
 * 수동 배송완료 버튼(AdminOrdersPage)과 공존: UPDATE에 status='shipping' 조건이 있어
 * 먼저 처리된 쪽만 적용되는 멱등 구조.
 *
 * 검증용: ?dryRun=1 → CJ 조회·판정까지만 하고 DB 변경/알림 없이 결과 반환.
 *
 * CJ 플러밍은 cj-tracking.js와 동일 규격(V3.9.4: 1Day 토큰 → CJ-Gateway-APIKey 헤더).
 * 화물상태 기초 코드(규격서 1.2.1): 01 집화지시 / 11 집화처리 / 12 미집화 / 41 간선상차 /
 * 42 간선하차 / 82 배송출발 / 84 미배송 / 91 배송완료
 */

const CJ_REQUEST_TIMEOUT_MS = Number(process.env.CJ_REQUEST_TIMEOUT_MS) || 12_000;
const CJ_RETRY_COUNT = Number(process.env.CJ_RETRY_COUNT) || 2;
const DELIVERED_STATUS_CODE = "91";

const DEFAULT_TOKEN_ENDPOINT = "/ReqOneDayToken";
const DEFAULT_TRACKING_ENDPOINT = "/ReqOneGdsTrc";

function isMockMode() {
  return (
    process.env.CJ_LOGISTICS_MOCK === "true" ||
    String(process.env.CJ_LOGISTICS_MODE || "").toLowerCase() === "mock"
  );
}

function getCjConfig() {
  return {
    baseUrl:
      process.env.CJ_API_BASE_URL ||
      process.env.CJ_LOGISTICS_API_BASE_URL ||
      "",
    tokenEndpoint: process.env.CJ_TOKEN_ENDPOINT || DEFAULT_TOKEN_ENDPOINT,
    trackingEndpoint:
      process.env.CJ_TRACKING_ENDPOINT ||
      process.env.CJ_LOGISTICS_TRACKING_ENDPOINT ||
      DEFAULT_TRACKING_ENDPOINT,
    custId: process.env.CJ_CUST_ID || process.env.CJ_CUSTOMER_ID || "",
    // ⚠ CJ는 사업자번호를 숫자만으로 조회 (cj-tracking.js와 동일)
    bizRegNum: String(process.env.CJ_BIZ_REG_NUM || "").replace(/\D/g, ""),
  };
}

function joinUrl(baseUrl, endpoint) {
  const base = String(baseUrl || "").replace(/\/+$/, "");
  const path = String(endpoint || "").replace(/^\/+/, "");
  return `${base}/${path}`;
}

function parseExtraHeaders() {
  const raw = String(process.env.CJ_EXTRA_HEADERS_JSON || "").trim();
  if (!raw) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function buildCjHeaders(apiKey) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
    ...parseExtraHeaders(),
  };
  if (apiKey) {
    headers["CJ-Gateway-APIKey"] = apiKey;
  }
  return headers;
}

function makeTimeoutError(timeoutMs) {
  const error = new Error(`CJ API request exceeded ${timeoutMs}ms.`);
  error.code = "CJ_TIMEOUT";
  return error;
}

async function readResponseBody(response) {
  const text = await response.text();
  if (!text) {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return { rawText: text };
  }
}

function isRetryableStatus(status) {
  return status === 408 || status === 429 || status >= 500;
}

async function requestJsonWithRetry(url, options) {
  let lastError = null;

  for (let attempt = 0; attempt <= CJ_RETRY_COUNT; attempt += 1) {
    const controller = new AbortController();
    const timeoutId = setTimeout(
      () => controller.abort(makeTimeoutError(CJ_REQUEST_TIMEOUT_MS)),
      CJ_REQUEST_TIMEOUT_MS,
    );

    try {
      const response = await fetch(url, { ...options, signal: controller.signal });
      clearTimeout(timeoutId);

      const body = await readResponseBody(response);
      if (response.ok) {
        return { body, status: response.status };
      }

      const error = new Error(`CJ API HTTP ${response.status}`);
      error.code = "CJ_HTTP_ERROR";
      error.responseBody = body;

      if (attempt < CJ_RETRY_COUNT && isRetryableStatus(response.status)) {
        lastError = error;
        continue;
      }
      throw error;
    } catch (error) {
      clearTimeout(timeoutId);
      const normalizedError =
        error?.name === "AbortError" && error?.cause ? error.cause : error;
      lastError = normalizedError;

      const isTimeout =
        normalizedError?.code === "CJ_TIMEOUT" || normalizedError?.name === "AbortError";
      if (attempt < CJ_RETRY_COUNT && isTimeout) {
        continue;
      }
      throw normalizedError;
    }
  }

  throw lastError || new Error("CJ_API_REQUEST_FAILED");
}

function isCjSuccess(body) {
  return String(body?.RESULT_CD || "").toUpperCase().startsWith("S");
}

function getCjMessage(body) {
  return String(body?.RESULT_DETAIL ?? "").trim();
}

async function postCj(cfg, endpoint, data, apiKey) {
  if (!cfg.baseUrl) {
    const error = new Error("CJ_API_BASE_URL is required.");
    error.code = "CJ_CONFIG_MISSING";
    throw error;
  }

  const { body } = await requestJsonWithRetry(joinUrl(cfg.baseUrl, endpoint), {
    method: "POST",
    headers: buildCjHeaders(apiKey),
    body: JSON.stringify({ DATA: data }),
  });

  return body;
}

async function getOneDayToken(cfg) {
  if (isMockMode()) {
    return `MOCK-TOKEN-${Date.now()}`;
  }

  if (!cfg.custId) {
    const error = new Error("CJ_CUST_ID(고객사코드)가 설정되지 않았습니다.");
    error.code = "CJ_CUST_ID_MISSING";
    throw error;
  }

  const body = await postCj(cfg, cfg.tokenEndpoint, {
    CUST_ID: cfg.custId,
    BIZ_REG_NUM: cfg.bizRegNum,
  }, "");

  if (!isCjSuccess(body)) {
    const error = new Error(getCjMessage(body) || "CJ 토큰 발급에 실패했습니다.");
    error.code = "CJ_TOKEN_FAILED";
    throw error;
  }

  const token = String(body?.DATA?.TOKEN_NUM || "").trim();
  if (!token) {
    const error = new Error("CJ 토큰 응답에 TOKEN_NUM이 없습니다.");
    error.code = "CJ_TOKEN_EMPTY";
    throw error;
  }

  return token;
}

// 최신 이벤트 기준 화물상태 조회. mock 모드에선 항상 미완료(82) 취급 — 실DB를 안 건드리게.
async function fetchLatestCargoStatus(cfg, token, waybillNo) {
  if (isMockMode()) {
    return { statusCode: "82", statusText: "배송출발(mock)" };
  }

  const body = await postCj(cfg, cfg.trackingEndpoint, {
    CLNTNUM: cfg.custId,
    INVC_NO: waybillNo,
    TOKEN_NUM: token,
  }, token);

  if (!isCjSuccess(body)) {
    const message = getCjMessage(body);
    // 채번 직후 ~ 집화 스캔 전에는 추적 데이터가 원래 없다 (2026-07-24 실측:
    // 공개 조회 페이지도 동일하게 빈 결과). 에러가 아니라 "아직 없음"으로 취급 → 다음 크론 재확인.
    if (/no data/i.test(message)) {
      return { statusCode: null, statusText: "추적 데이터 없음(집화 스캔 전)", noData: true };
    }
    const error = new Error(message || "CJ 배송 추적 조회에 실패했습니다.");
    error.code = "CJ_TRACKING_FAILED";
    throw error;
  }

  const rawArray = Array.isArray(body?.DATA)
    ? body.DATA
    : Array.isArray(body?.DATA?.ARRAY)
      ? body.DATA.ARRAY
      : [];

  let latest = null;
  for (const event of rawArray) {
    if (!event || typeof event !== "object") continue;
    const ymd = String(event.SCAN_YMD || "").trim();
    const hour = String(event.SCAN_HOUR || "").trim();
    const occurredAt = ymd ? (hour ? `${ymd} ${hour}` : ymd) : "";
    // occurredAt('YYYYMMDD HHMMSS')는 문자열 비교로 시간순 정렬 가능.
    if (!latest || occurredAt >= latest.occurredAt) {
      latest = {
        occurredAt,
        statusCode: event.CRG_ST != null ? String(event.CRG_ST) : null,
        statusText: String(event.CRG_ST_NM || "").trim() || null,
      };
    }
  }

  return latest || { statusCode: null, statusText: null };
}

function isDeliveredStatus({ statusCode, statusText }) {
  if (String(statusCode || "").trim() === DELIVERED_STATUS_CODE) {
    return true;
  }
  return /배송완료|배달완료/.test(String(statusText || ""));
}

async function notifyBuyerDelivered({ baseUrl, cronSecret, order }) {
  const url = `${baseUrl}/api/admin/send-notification`;
  const body = {
    notificationType: "delivery_done",
    recipientPhone: order.shipping_recipient_phone,
    recipientName: order.shipping_recipient_name,
    recipientUserId: order.user_id,
    refType: "order",
    refId: order.id,
    templateVariables: {},
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
    console.error("notifyBuyerDelivered fetch failed:", err.message);
    return { ok: false, status: 0 };
  }
}

export default async function handler(req, res) {
  // ⚠️ Cron 요청 검증 (fail-close): CRON_SECRET 미설정이면 항상 401.
  const authHeader = req.headers.authorization;
  const cronSecret = process.env.CRON_SECRET;

  if (!cronSecret) {
    console.error("CRON_SECRET env not configured");
    return res.status(401).json({ error: "Unauthorized" });
  }
  if (authHeader !== `Bearer ${cronSecret}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  if (req.method !== "GET") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const dryRun =
    String(req.query?.dryRun ?? "") === "1" || String(req.query?.dryRun ?? "") === "true";

  // ⚠️ service_role은 VITE_* fallback 금지 (auto-confirm-orders.js와 동일 사유)
  const supabaseUrl =
    process.env.SUPABASE_URL ||
    process.env.SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_URL;
  const supabaseServiceKey =
    process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;

  if (!supabaseUrl || !supabaseServiceKey) {
    return res.status(500).json({ error: "Missing Supabase configuration" });
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const { data: orders, error: listError } = await supabase
      .from("orders")
      .select("id, order_number, user_id, tracking_number, shipping_recipient_name, shipping_recipient_phone")
      .eq("status", "shipping")
      .not("tracking_number", "is", null)
      .order("id");

    if (listError) {
      console.error("shipping orders fetch error:", listError.message);
      return res.status(500).json({ error: listError.message });
    }

    const targets = (orders ?? []).filter((o) => String(o.tracking_number || "").trim());
    const results = [];
    let deliveredCount = 0;
    let notifySent = 0;
    let notifyFailed = 0;

    if (targets.length > 0) {
      const cfg = getCjConfig();
      // 토큰은 배치당 1회 발급 (1Day 토큰 — 규격서 p6)
      const token = await getOneDayToken(cfg);

      const protocol = req.headers["x-forwarded-proto"] || "https";
      const host = req.headers["x-forwarded-host"] || req.headers.host;
      const baseUrl = `${protocol}://${host}`;

      // 함수 실행 한도(300s) 가드: CJ가 전건 타임아웃하는 최악 케이스에도 한도 전에
      // 멈추고 나머지는 다음 크론으로 이월 (미전환 건은 shipping으로 남아 자동 재시도).
      const startedAt = Date.now();
      const SOFT_DEADLINE_MS = 240_000;

      for (const order of targets) {
        if (Date.now() - startedAt > SOFT_DEADLINE_MS) {
          results.push({ order_id: order.id, skipped: "soft-deadline — 다음 크론에서 처리" });
          continue;
        }
        const entry = {
          order_id: order.id,
          order_number: order.order_number,
          tracking_number: order.tracking_number,
        };

        try {
          const latest = await fetchLatestCargoStatus(cfg, token, String(order.tracking_number).trim());
          entry.cj_status_code = latest.statusCode;
          entry.cj_status_text = latest.statusText;
          entry.delivered = isDeliveredStatus(latest);

          if (entry.delivered && !dryRun) {
            // status='shipping' 조건으로 멱등 보장 (수동 버튼과 경합 시 먼저 처리된 쪽 승리).
            // delivered 전이 = admin_update_order_status와 동일하게 auto_confirm_at D+7 스탬프.
            const { data: updated, error: updateError } = await supabase
              .from("orders")
              .update({
                status: "delivered",
                auto_confirm_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
                updated_at: new Date().toISOString(),
              })
              .eq("id", order.id)
              .eq("status", "shipping")
              .select("id");

            if (updateError) {
              entry.transitioned = false;
              entry.error = updateError.message;
            } else {
              entry.transitioned = (updated ?? []).length > 0;
            }

            if (entry.transitioned) {
              deliveredCount += 1;
              const notifyResult = await notifyBuyerDelivered({ baseUrl, cronSecret, order });
              entry.notified = notifyResult.ok;
              if (notifyResult.ok) notifySent += 1;
              else notifyFailed += 1;
            }
          }
        } catch (err) {
          // 개별 주문 실패는 배치를 중단하지 않는다 (다음 크론에서 재시도됨)
          entry.error = err?.message || String(err);
          console.error(`CJ tracking failed for order ${order.id}:`, entry.error);
        }

        results.push(entry);
      }
    }

    const summary = {
      checked: targets.length,
      delivered_transitioned: deliveredCount,
      notifications_sent: notifySent,
      notifications_failed: notifyFailed,
      dry_run: dryRun,
      results,
    };
    console.log("cj-delivery-tracking result:", JSON.stringify(summary));
    return res.status(200).json(summary);
  } catch (err) {
    console.error("cj-delivery-tracking unexpected error:", err);
    return res.status(500).json({ error: err?.message || "Internal server error" });
  }
}
