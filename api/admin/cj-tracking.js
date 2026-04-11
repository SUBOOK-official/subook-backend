import { createClient } from "@supabase/supabase-js";

const CJ_REQUEST_TIMEOUT_MS = 3_000;
const CJ_RETRY_COUNT = 1;
const DEFAULT_CJ_TRACKING_ENDPOINT = "/tracking/{waybillNo}";
const CJ_CARRIER_NAME = "CJ대한통운";

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
    serviceKey:
      process.env.SUPABASE_SERVICE_ROLE_KEY ||
      process.env.SUPABASE_SERVICE_KEY ||
      process.env.VITE_SUPABASE_ADMIN_KEY,
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
    baseUrl: process.env.CJ_API_BASE_URL || process.env.CJ_LOGISTICS_API_BASE_URL || "",
    trackingEndpoint:
      process.env.CJ_TRACKING_ENDPOINT ||
      process.env.CJ_LOGISTICS_TRACKING_ENDPOINT ||
      DEFAULT_CJ_TRACKING_ENDPOINT,
  };
}

function normalizeTrackingNumber(value) {
  return String(value || "").replace(/[^0-9A-Za-z]/g, "").trim();
}

function joinTrackingUrl(baseUrl, endpoint, waybillNo) {
  const base = String(baseUrl || "").replace(/\/+$/, "");
  const path = String(endpoint || DEFAULT_CJ_TRACKING_ENDPOINT)
    .replace("{waybillNo}", encodeURIComponent(waybillNo))
    .replace(":waybillNo", encodeURIComponent(waybillNo))
    .replace(/^\/+/, "");

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
  const headers = {
    "Content-Type": "application/json;charset=UTF-8",
    ...parseExtraHeaders(),
  };

  const apiKey = process.env.CJ_API_KEY || process.env.CJ_LOGISTICS_API_KEY || "";
  const apiSecret = process.env.CJ_API_SECRET || process.env.CJ_LOGISTICS_API_SECRET || "";
  const customerId = process.env.CJ_CUSTOMER_ID || process.env.CJ_LOGISTICS_CUSTOMER_ID || "";
  const contractId = process.env.CJ_CONTRACT_ID || process.env.CJ_LOGISTICS_CONTRACT_ID || "";

  const apiKeyHeader = process.env.CJ_API_KEY_HEADER || "";
  if (apiKey && apiKeyHeader) {
    headers[apiKeyHeader] = apiKey;
  } else if (apiKey) {
    const authHeader = process.env.CJ_API_AUTH_HEADER || "Authorization";
    const authScheme = process.env.CJ_API_AUTH_SCHEME || "Bearer";
    headers[authHeader] = authScheme ? `${authScheme} ${apiKey}` : apiKey;
  }

  const secretHeader = process.env.CJ_API_SECRET_HEADER || "";
  if (apiSecret && secretHeader) {
    headers[secretHeader] = apiSecret;
  }

  const customerHeader = process.env.CJ_CUSTOMER_ID_HEADER || "";
  if (customerId && customerHeader) {
    headers[customerHeader] = customerId;
  }

  const contractHeader = process.env.CJ_CONTRACT_ID_HEADER || "";
  if (contractId && contractHeader) {
    headers[contractHeader] = contractId;
  }

  return headers;
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

function getPathValue(source, path) {
  return path.split(".").reduce((current, key) => {
    if (current === null || current === undefined) {
      return undefined;
    }
    return current[key];
  }, source);
}

function extractFirstString(source, paths) {
  for (const path of paths) {
    const value = getPathValue(source, path);
    if (value !== null && value !== undefined && String(value).trim()) {
      return String(value).trim();
    }
  }

  return "";
}

function extractFirstArray(source, paths) {
  for (const path of paths) {
    const value = getPathValue(source, path);
    if (Array.isArray(value)) {
      return value;
    }
  }

  return [];
}

function normalizeTrackingEvents(events) {
  return events
    .filter((event) => event && typeof event === "object")
    .map((event) => ({
      statusCode:
        event.statusCode ||
        event.status_code ||
        event.code ||
        event.scanCode ||
        event.scan_code ||
        null,
      statusText:
        event.statusText ||
        event.status_text ||
        event.status ||
        event.description ||
        event.message ||
        event.scanName ||
        event.scan_name ||
        null,
      location:
        event.location ||
        event.branchName ||
        event.branch_name ||
        event.office ||
        null,
      occurredAt:
        event.occurredAt ||
        event.occurred_at ||
        event.time ||
        event.datetime ||
        event.createdAt ||
        event.created_at ||
        null,
    }));
}

function normalizeTrackingResponse(waybillNo, responseBody) {
  const events = normalizeTrackingEvents(
    extractFirstArray(responseBody, [
      "events",
      "history",
      "histories",
      "trackingEvents",
      "data.events",
      "data.history",
      "data.histories",
      "data.trackingEvents",
      "result.events",
      "result.history",
      "result.histories",
      "result.trackingEvents",
    ]),
  );

  const lastEvent = events[events.length - 1] || {};
  const statusCode =
    extractFirstString(responseBody, [
      "statusCode",
      "status_code",
      "code",
      "data.statusCode",
      "data.status_code",
      "data.code",
      "result.statusCode",
      "result.status_code",
      "result.code",
    ]) ||
    lastEvent.statusCode ||
    "";
  const statusText =
    extractFirstString(responseBody, [
      "statusText",
      "status_text",
      "status",
      "message",
      "description",
      "data.statusText",
      "data.status_text",
      "data.status",
      "data.message",
      "result.statusText",
      "result.status_text",
      "result.status",
      "result.message",
    ]) ||
    lastEvent.statusText ||
    "";

  return {
    waybillNo,
    carrier: CJ_CARRIER_NAME,
    statusCode: statusCode ? String(statusCode) : null,
    statusText: statusText ? String(statusText) : "상태 미확인",
    events,
    rawResponse: responseBody,
  };
}

async function fetchCjTracking(waybillNo) {
  if (isMockMode()) {
    return {
      waybillNo,
      carrier: CJ_CARRIER_NAME,
      statusCode: "PICKUP_SCHEDULED",
      statusText: "수거접수",
      events: [
        {
          statusCode: "PICKUP_SCHEDULED",
          statusText: "수거접수",
          location: "CJ대한통운",
          occurredAt: new Date().toISOString(),
        },
      ],
      rawResponse: {
        mock: true,
        waybillNo,
        statusCode: "PICKUP_SCHEDULED",
        statusText: "수거접수",
      },
    };
  }

  const config = getCjConfig();
  if (!config.baseUrl) {
    const error = new Error("CJ_API_BASE_URL is required. Set CJ_LOGISTICS_MOCK=true for local mock mode.");
    error.code = "CJ_CONFIG_MISSING";
    error.statusCode = 500;
    throw error;
  }

  const url = joinTrackingUrl(config.baseUrl, config.trackingEndpoint, waybillNo);
  const { body } = await requestJsonWithRetry(url, {
    method: "GET",
    headers: buildCjHeaders(),
  });

  return normalizeTrackingResponse(waybillNo, body);
}

function mapTrackingToPickupStatus({ statusCode, statusText }) {
  const haystack = `${statusCode || ""} ${statusText || ""}`.toLowerCase();

  if (/cancel|취소|반송/.test(haystack)) {
    return "cancelled";
  }
  if (/delivered|complete|배송완료|배달완료|도착|입고/.test(haystack)) {
    return "arrived";
  }
  if (/pickup|collect|picked|집화|수거|인수|상품인수|배송중|이동중/.test(haystack)) {
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
