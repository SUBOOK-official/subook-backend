import { createClient } from "@supabase/supabase-js";

// ──────────────────────────────────────────────────────────────────────────
// CJ대한통운 Open API (택배 표준 API) — 배송(집화) 추적
//
// 흐름: ReqOneDayToken(1Day 토큰) → ReqOneGdsTrc(운송장번호 기준 단건 추적)
// 인증: 헤더 CJ-Gateway-APIKey + 바디 DATA.TOKEN_NUM
// 응답 DATA: [ { CRG_ST(상태코드), CRG_ST_NM(상태명), SCAN_YMD, SCAN_HOUR,
//               DEALT_BRAN_NM(담당점소), INVC_NO, ACPTR_NM(인수자) }, ... ]
// 규격: 개발자포털 자료실 "CJLAPI-택배 표준 API Developer Guide" (V3.9.4) 기준
// ──────────────────────────────────────────────────────────────────────────

const CJ_REQUEST_TIMEOUT_MS = Number(process.env.CJ_REQUEST_TIMEOUT_MS) || 12_000;
const CJ_RETRY_COUNT = Number(process.env.CJ_RETRY_COUNT) || 2;
const CJ_CARRIER_NAME = "CJ대한통운";

const DEFAULT_TOKEN_ENDPOINT = "/ReqOneDayToken";
const DEFAULT_TRACKING_ENDPOINT = "/ReqOneGdsTrc";

const PICKUP_SELECT = `
  id,
  user_id,
  request_number,
  status,
  pickup_recipient_name,
  pickup_recipient_phone,
  item_count,
  tracking_number,
  tracking_carrier,
  cj_tracking_status,
  cj_tracking_status_code,
  cj_tracking_last_checked_at,
  cj_tracking_history,
  created_at,
  updated_at
`;

const PICKUP_STATUS_RANK = {
  pending: 0,
  pickup_scheduled: 1,
  picking_up: 2,
  arrived: 3,
  inspecting: 4,
  inspected: 5,
  completed: 6,
  cancelled: 99,
};

function makeErrorResponse({ error, code, detail }) {
  const payload = {
    error: String(error || "Request failed."),
    code: String(code || "UNKNOWN"),
  };

  if (detail) {
    payload.detail = String(detail);
  }

  return payload;
}

function parseBearerToken(authHeader) {
  const match = String(authHeader || "").match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || "";
}

function getSupabaseConfig() {
  return {
    url:
      process.env.SUPABASE_URL ||
      process.env.SUPABASE_ADMIN_URL ||
      process.env.VITE_SUPABASE_ADMIN_URL ||
      process.env.VITE_SUPABASE_URL,
    anonKey:
      process.env.SUPABASE_ANON_KEY ||
      process.env.SUPABASE_ADMIN_ANON_KEY ||
      process.env.VITE_SUPABASE_ADMIN_ANON_KEY ||
      process.env.VITE_SUPABASE_ANON_KEY,
    // ⚠️ service_role은 VITE_* fallback 금지 (VITE_ prefix는 client 번들에 embed됨)
    serviceKey:
      process.env.SUPABASE_SERVICE_ROLE_KEY ||
      process.env.SUPABASE_SERVICE_KEY,
  };
}

async function assertAdminUser(accessToken) {
  const { url, anonKey } = getSupabaseConfig();
  if (!url || !anonKey) {
    const error = new Error("SUPABASE_CONFIG_MISSING");
    error.statusCode = 500;
    throw error;
  }

  const supabase = createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userResult, error: userError } = await supabase.auth.getUser(accessToken);
  if (userError || !userResult?.user) {
    const error = new Error("UNAUTHORIZED");
    error.statusCode = 401;
    throw error;
  }

  const { data: isAdmin, error: adminError } = await supabase.rpc("is_admin_user");
  if (adminError || !isAdmin) {
    const error = new Error("FORBIDDEN");
    error.statusCode = 403;
    throw error;
  }
}

function createServiceClient() {
  const { url, serviceKey } = getSupabaseConfig();
  if (!url || !serviceKey) {
    const error = new Error("SUPABASE_SERVICE_CONFIG_MISSING");
    error.statusCode = 500;
    throw error;
  }

  return createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

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
    bizRegNum: process.env.CJ_BIZ_REG_NUM || "",
  };
}

function normalizeTrackingNumber(value) {
  return String(value || "").replace(/[^0-9A-Za-z]/g, "").trim();
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

function buildCjHeaders() {
  const gatewayKey =
    process.env.CJ_GATEWAY_API_KEY ||
    process.env.CJ_API_KEY ||
    process.env.CJ_LOGISTICS_API_KEY ||
    "";

  return {
    "Content-Type": "application/json",
    Accept: "application/json",
    "CJ-Gateway-APIKey": gatewayKey,
    ...parseExtraHeaders(),
  };
}

function makeTimeoutError(timeoutMs) {
  const error = new Error(`CJ API request exceeded ${timeoutMs}ms.`);
  error.code = "CJ_TIMEOUT";
  error.statusCode = 504;
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
    const timeoutId = setTimeout(() => controller.abort(makeTimeoutError(CJ_REQUEST_TIMEOUT_MS)), CJ_REQUEST_TIMEOUT_MS);

    try {
      const response = await fetch(url, {
        ...options,
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      const body = await readResponseBody(response);
      if (response.ok) {
        return { body, status: response.status };
      }

      const error = new Error(`CJ API HTTP ${response.status}`);
      error.code = "CJ_HTTP_ERROR";
      error.statusCode = response.status;
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

      const isTimeout = normalizedError?.code === "CJ_TIMEOUT" || normalizedError?.name === "AbortError";
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

async function postCj(cfg, endpoint, data) {
  if (!cfg.baseUrl) {
    const error = new Error("CJ_API_BASE_URL is required. Set CJ_LOGISTICS_MOCK=true for local mock mode.");
    error.code = "CJ_CONFIG_MISSING";
    error.statusCode = 500;
    throw error;
  }

  const { body } = await requestJsonWithRetry(joinUrl(cfg.baseUrl, endpoint), {
    method: "POST",
    headers: buildCjHeaders(),
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
    error.statusCode = 500;
    throw error;
  }

  const body = await postCj(cfg, cfg.tokenEndpoint, {
    CUST_ID: cfg.custId,
    BIZ_REG_NUM: cfg.bizRegNum,
  });

  if (!isCjSuccess(body)) {
    const error = new Error(getCjMessage(body) || "CJ 토큰 발급에 실패했습니다.");
    error.code = "CJ_TOKEN_FAILED";
    error.statusCode = 502;
    error.responseBody = body;
    throw error;
  }

  const token = String(body?.DATA?.TOKEN_NUM || "").trim();
  if (!token) {
    const error = new Error("CJ 토큰 응답에 TOKEN_NUM이 없습니다.");
    error.code = "CJ_TOKEN_EMPTY";
    error.statusCode = 502;
    error.responseBody = body;
    throw error;
  }

  return token;
}

function pad2(value) {
  return String(value || "").padStart(2, "0");
}

// CJ 추적 이벤트(DATA[] 요소) → 내부 정규화 이벤트.
function normalizeTrackingEvents(events) {
  return events
    .filter((event) => event && typeof event === "object")
    .map((event) => {
      const ymd = String(event.SCAN_YMD || "").trim();
      const hour = String(event.SCAN_HOUR || "").trim();
      const occurredAt = ymd ? (hour ? `${ymd} ${hour}` : ymd) : null;
      return {
        statusCode: event.CRG_ST != null ? String(event.CRG_ST) : null,
        statusText: String(event.CRG_ST_NM || "").trim() || null,
        location: String(event.DEALT_BRAN_NM || "").trim() || null,
        occurredAt,
        receiver: String(event.ACPTR_NM || "").trim() || null,
      };
    });
}

function pickLatestEvent(events) {
  let latest = null;
  for (const event of events) {
    if (!latest) {
      latest = event;
      continue;
    }
    // occurredAt('YYYY-MM-DD HH:MM:SS')는 문자열 비교로 시간순 정렬 가능.
    if (String(event.occurredAt || "") >= String(latest.occurredAt || "")) {
      latest = event;
    }
  }
  return latest || {};
}

function normalizeTrackingResponse(waybillNo, responseBody) {
  const rawArray = Array.isArray(responseBody?.DATA)
    ? responseBody.DATA
    : Array.isArray(responseBody?.DATA?.ARRAY)
      ? responseBody.DATA.ARRAY
      : [];

  const events = normalizeTrackingEvents(rawArray);
  const latest = pickLatestEvent(events);

  return {
    waybillNo,
    carrier: CJ_CARRIER_NAME,
    statusCode: latest.statusCode ? String(latest.statusCode) : null,
    statusText: latest.statusText ? String(latest.statusText) : "상태 미확인",
    events,
    rawResponse: responseBody,
  };
}

async function fetchCjTracking(waybillNo) {
  if (isMockMode()) {
    return {
      waybillNo,
      carrier: CJ_CARRIER_NAME,
      statusCode: "11",
      statusText: "집화접수",
      events: [
        {
          statusCode: "11",
          statusText: "집화접수",
          location: "CJ대한통운",
          occurredAt: new Date().toISOString(),
          receiver: null,
        },
      ],
      rawResponse: { mock: true, RESULT_CD: "S", waybillNo },
    };
  }

  const cfg = getCjConfig();
  const token = await getOneDayToken(cfg);

  const body = await postCj(cfg, cfg.trackingEndpoint, {
    CLNTNUM: cfg.custId,
    INVC_NO: waybillNo,
    TOKEN_NUM: token,
  });

  if (!isCjSuccess(body)) {
    const error = new Error(getCjMessage(body) || "CJ 배송 추적 조회에 실패했습니다.");
    error.code = "CJ_TRACKING_FAILED";
    error.statusCode = 502;
    error.responseBody = body;
    throw error;
  }

  return normalizeTrackingResponse(waybillNo, body);
}

function mapTrackingToPickupStatus({ statusCode, statusText }) {
  const haystack = `${statusCode || ""} ${statusText || ""}`.toLowerCase();

  if (/cancel|취소|반송|반품/.test(haystack)) {
    return "cancelled";
  }
  if (/delivered|complete|배송완료|배달완료|도착|입고/.test(haystack)) {
    return "arrived";
  }
  if (/pickup|collect|picked|집화|수거|인수|상품인수|배송중|이동중|간선/.test(haystack)) {
    return "picking_up";
  }
  if (/accept|register|예약|접수|scheduled|received/.test(haystack)) {
    return "pickup_scheduled";
  }

  return null;
}

function chooseNextPickupStatus(currentStatus, mappedStatus) {
  if (!mappedStatus) {
    return currentStatus;
  }

  if (["inspecting", "inspected", "completed"].includes(currentStatus)) {
    return currentStatus;
  }

  if (mappedStatus === "cancelled") {
    return currentStatus === "completed" ? currentStatus : mappedStatus;
  }

  const currentRank = PICKUP_STATUS_RANK[currentStatus] ?? 0;
  const nextRank = PICKUP_STATUS_RANK[mappedStatus] ?? currentRank;
  return nextRank >= currentRank ? mappedStatus : currentStatus;
}

function getQueryValue(req, key) {
  if (req.query && req.query[key] !== undefined) {
    const value = req.query[key];
    return Array.isArray(value) ? value[0] : value;
  }

  const url = new URL(req.url || "", "http://localhost");
  return url.searchParams.get(key);
}

async function getPickupRequest(supabase, pickupRequestId) {
  const { data, error } = await supabase
    .from("pickup_requests")
    .select(PICKUP_SELECT)
    .eq("id", pickupRequestId)
    .maybeSingle();

  if (error) {
    throw error;
  }

  return data;
}

async function saveLogisticsEvent(supabase, event) {
  const { error } = await supabase.from("pickup_logistics_events").insert(event);
  if (error) {
    console.error("[cj-tracking] failed to save logistics event", error.message);
  }
}

function getErrorDetail(error) {
  const responseDetail = error?.responseBody
    ? JSON.stringify(error.responseBody).slice(0, 500)
    : "";
  return responseDetail || String(error?.message || "").slice(0, 500);
}

export default async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json(
      makeErrorResponse({
        error: "Method not allowed.",
        code: "METHOD_NOT_ALLOWED",
      }),
    );
  }

  const accessToken = parseBearerToken(req.headers.authorization);
  if (!accessToken) {
    return res.status(401).json(
      makeErrorResponse({
        error: "Missing authorization token.",
        code: "MISSING_AUTH_TOKEN",
      }),
    );
  }

  try {
    await assertAdminUser(accessToken);
    const supabase = createServiceClient();

    const pickupRequestId = Number.parseInt(String(getQueryValue(req, "pickupRequestId") || ""), 10);
    const directWaybillNo = normalizeTrackingNumber(
      getQueryValue(req, "waybillNo") || getQueryValue(req, "trackingNumber"),
    );

    let pickupRequest = null;
    if (Number.isInteger(pickupRequestId) && pickupRequestId > 0) {
      pickupRequest = await getPickupRequest(supabase, pickupRequestId);
      if (!pickupRequest) {
        return res.status(404).json(
          makeErrorResponse({
            error: "수거 요청을 찾을 수 없습니다.",
            code: "PICKUP_NOT_FOUND",
          }),
        );
      }
    }

    const waybillNo = normalizeTrackingNumber(directWaybillNo || pickupRequest?.tracking_number);
    if (!waybillNo) {
      return res.status(400).json(
        makeErrorResponse({
          error: "waybillNo 또는 pickupRequestId의 운송장이 필요합니다.",
          code: "MISSING_WAYBILL_NO",
        }),
      );
    }

    const tracking = await fetchCjTracking(waybillNo);
    let updatedPickupRequest = pickupRequest;

    if (pickupRequest) {
      const mappedStatus = mapTrackingToPickupStatus(tracking);
      const nextStatus = chooseNextPickupStatus(pickupRequest.status, mappedStatus);
      const checkedAt = new Date().toISOString();

      const { error: updateError } = await supabase
        .from("pickup_requests")
        .update({
          status: nextStatus,
          tracking_number: waybillNo,
          tracking_carrier: CJ_CARRIER_NAME,
          cj_tracking_status: tracking.statusText,
          cj_tracking_status_code: tracking.statusCode,
          cj_tracking_last_checked_at: checkedAt,
          cj_tracking_history: tracking.events,
          cj_tracking_response: tracking.rawResponse,
        })
        .eq("id", pickupRequest.id);

      if (updateError) {
        throw updateError;
      }

      await saveLogisticsEvent(supabase, {
        pickup_request_id: pickupRequest.id,
        event_type: "tracking_lookup",
        status: "success",
        tracking_number: waybillNo,
        status_code: tracking.statusCode,
        status_text: tracking.statusText,
        payload: tracking.rawResponse,
      });

      updatedPickupRequest = await getPickupRequest(supabase, pickupRequest.id);
    }

    return res.status(200).json({
      success: true,
      tracking,
      pickupRequest: updatedPickupRequest,
    });
  } catch (error) {
    const statusCode = error?.statusCode || 500;
    const code =
      statusCode === 401
        ? "AUTH_REQUIRED"
        : statusCode === 403
          ? "ADMIN_REQUIRED"
          : error?.code || error?.message || "CJ_TRACKING_HANDLER_FAILED";

    console.error("[cj-tracking] handler failure", {
      statusCode,
      code,
      message: error?.message || "",
    });

    return res.status(statusCode).json(
      makeErrorResponse({
        error: statusCode === 403 ? "Admin access required." : "CJ tracking lookup failed.",
        code,
        detail: getErrorDetail(error),
      }),
    );
  }
}
