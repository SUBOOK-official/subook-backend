import { createClient } from "@supabase/supabase-js";

const CJ_REQUEST_TIMEOUT_MS = 3_000;
const CJ_RETRY_COUNT = 1;
const MAX_BULK_PICKUP_COUNT = 30;
const DEFAULT_CJ_PICKUP_ENDPOINT = "/pickup";
const CJ_CARRIER_NAME = "CJ대한통운";

const PICKUP_SELECT = `
  id,
  user_id,
  request_number,
  status,
  pickup_recipient_name,
  pickup_recipient_phone,
  pickup_postal_code,
  pickup_address_line1,
  pickup_address_line2,
  pickup_memo,
  item_count,
  tracking_number,
  tracking_carrier,
  cj_request_id,
  cj_pickup_registered_at,
  cj_tracking_status,
  cj_tracking_status_code,
  cj_tracking_last_checked_at,
  created_at,
  updated_at,
  pickup_items (
    id,
    title,
    subject,
    brand,
    book_type,
    published_year,
    instructor_name,
    original_price,
    condition_memo,
    is_manual_entry
  )
`;

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

function parseJsonBody(req) {
  if (!req.body) {
    return {};
  }

  if (typeof req.body === "string") {
    return JSON.parse(req.body || "{}");
  }

  return req.body;
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

  return userResult.user;
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

function normalizeEndpoint(endpoint) {
  const text = String(endpoint || "").trim();
  return text || DEFAULT_CJ_PICKUP_ENDPOINT;
}

function joinUrl(baseUrl, endpoint) {
  const base = String(baseUrl || "").replace(/\/+$/, "");
  const path = normalizeEndpoint(endpoint).replace(/^\/+/, "");
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

function getCjConfig() {
  return {
    baseUrl: process.env.CJ_API_BASE_URL || process.env.CJ_LOGISTICS_API_BASE_URL || "",
    pickupEndpoint:
      process.env.CJ_PICKUP_ENDPOINT ||
      process.env.CJ_LOGISTICS_PICKUP_ENDPOINT ||
      DEFAULT_CJ_PICKUP_ENDPOINT,
    customerId: process.env.CJ_CUSTOMER_ID || process.env.CJ_LOGISTICS_CUSTOMER_ID || "",
    contractId: process.env.CJ_CONTRACT_ID || process.env.CJ_LOGISTICS_CONTRACT_ID || "",
    warehouseName:
      process.env.CJ_WAREHOUSE_NAME ||
      process.env.SUBOOK_WAREHOUSE_NAME ||
      "수북 입고센터",
    warehousePhone:
      process.env.CJ_WAREHOUSE_PHONE ||
      process.env.SUBOOK_WAREHOUSE_PHONE ||
      "",
    warehousePostalCode:
      process.env.CJ_WAREHOUSE_POSTAL_CODE ||
      process.env.SUBOOK_WAREHOUSE_POSTAL_CODE ||
      "",
    warehouseAddressLine1:
      process.env.CJ_WAREHOUSE_ADDRESS_LINE1 ||
      process.env.SUBOOK_WAREHOUSE_ADDRESS_LINE1 ||
      "",
    warehouseAddressLine2:
      process.env.CJ_WAREHOUSE_ADDRESS_LINE2 ||
      process.env.SUBOOK_WAREHOUSE_ADDRESS_LINE2 ||
      "",
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

function normalizeTrackingNumber(value) {
  return String(value || "").replace(/[^0-9A-Za-z]/g, "").trim();
}

function extractTrackingNumber(responseBody) {
  return normalizeTrackingNumber(
    extractFirstString(responseBody, [
      "trackingNumber",
      "tracking_number",
      "waybillNo",
      "waybill_no",
      "invoiceNo",
      "invoice_no",
      "slipNo",
      "slip_no",
      "data.trackingNumber",
      "data.tracking_number",
      "data.waybillNo",
      "data.invoiceNo",
      "data.slipNo",
      "result.trackingNumber",
      "result.waybillNo",
      "result.invoiceNo",
      "result.slipNo",
    ]),
  );
}

function extractCjRequestId(responseBody) {
  return extractFirstString(responseBody, [
    "requestId",
    "request_id",
    "receiptNo",
    "receipt_no",
    "reservationNo",
    "reservation_no",
    "data.requestId",
    "data.receiptNo",
    "data.reservationNo",
    "result.requestId",
    "result.receiptNo",
    "result.reservationNo",
  ]);
}

function makeMockTrackingNumber(pickupRequest) {
  const nowDigits = new Date().toISOString().replace(/\D/g, "").slice(2, 12);
  const idDigits = String(pickupRequest.id || 0).padStart(6, "0").slice(-6);
  return `${nowDigits}${idDigits}`.slice(-12).padStart(12, "0");
}

function buildPickupRegistrationPayload(pickupRequest) {
  const config = getCjConfig();
  const items = Array.isArray(pickupRequest.pickup_items) ? pickupRequest.pickup_items : [];

  return {
    customerId: config.customerId || undefined,
    contractId: config.contractId || undefined,
    orderNo: pickupRequest.request_number,
    requestNumber: pickupRequest.request_number,
    carrier: CJ_CARRIER_NAME,
    pickup: {
      name: pickupRequest.pickup_recipient_name,
      phone: pickupRequest.pickup_recipient_phone,
      postalCode: pickupRequest.pickup_postal_code,
      addressLine1: pickupRequest.pickup_address_line1,
      addressLine2: pickupRequest.pickup_address_line2 || "",
      memo: pickupRequest.pickup_memo || "",
    },
    receiver: {
      name: config.warehouseName,
      phone: config.warehousePhone,
      postalCode: config.warehousePostalCode,
      addressLine1: config.warehouseAddressLine1,
      addressLine2: config.warehouseAddressLine2,
    },
    parcel: {
      quantity: 1,
      itemCount: pickupRequest.item_count || items.length || 1,
      itemName: items[0]?.title || "수능 교재",
      items: items.map((item) => ({
        id: item.id,
        title: item.title,
        subject: item.subject,
        brand: item.brand,
        bookType: item.book_type,
        originalPrice: item.original_price,
      })),
    },
  };
}

async function registerCjPickup(pickupRequest) {
  if (isMockMode()) {
    const trackingNumber = makeMockTrackingNumber(pickupRequest);
    return {
      trackingNumber,
      cjRequestId: `MOCK-${pickupRequest.request_number}`,
      rawResponse: {
        mock: true,
        trackingNumber,
        requestId: `MOCK-${pickupRequest.request_number}`,
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

  const url = joinUrl(config.baseUrl, config.pickupEndpoint);
  const payload = buildPickupRegistrationPayload(pickupRequest);
  const { body } = await requestJsonWithRetry(url, {
    method: "POST",
    headers: buildCjHeaders(),
    body: JSON.stringify(payload),
  });

  const trackingNumber = extractTrackingNumber(body);
  if (!trackingNumber) {
    const error = new Error("CJ API response did not include a tracking number.");
    error.code = "CJ_EMPTY_TRACKING_NUMBER";
    error.statusCode = 502;
    error.responseBody = body;
    throw error;
  }

  return {
    trackingNumber,
    cjRequestId: extractCjRequestId(body) || null,
    rawResponse: body,
  };
}

function getErrorDetail(error) {
  const responseDetail = error?.responseBody
    ? JSON.stringify(error.responseBody).slice(0, 500)
    : "";
  return responseDetail || String(error?.message || "").slice(0, 500);
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
    console.error("[cj-pickup] failed to save logistics event", error.message);
  }
}

function canRegisterPickup(pickupRequest) {
  return !["cancelled", "completed"].includes(pickupRequest.status);
}

function normalizeIds(value) {
  const source = Array.isArray(value) ? value : [value];
  return [
    ...new Set(
      source
        .map((item) => Number.parseInt(String(item), 10))
        .filter((item) => Number.isInteger(item) && item > 0),
    ),
  ];
}

async function processPickupRegistration({ supabase, pickupRequestId, force }) {
  const pickupRequest = await getPickupRequest(supabase, pickupRequestId);
  if (!pickupRequest) {
    return {
      pickupRequestId,
      success: false,
      status: "failed",
      error: "수거 요청을 찾을 수 없습니다.",
      code: "PICKUP_NOT_FOUND",
    };
  }

  if (pickupRequest.tracking_number && !force) {
    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: true,
      status: "skipped",
      trackingNumber: pickupRequest.tracking_number,
      pickupRequest,
    };
  }

  if (!canRegisterPickup(pickupRequest)) {
    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: false,
      status: "failed",
      error: `현재 상태에서는 CJ 접수가 불가능합니다. (${pickupRequest.status})`,
      code: "INVALID_PICKUP_STATUS",
    };
  }

  try {
    const cjResult = await registerCjPickup(pickupRequest);
    const registeredAt = new Date().toISOString();
    const { error: updateError } = await supabase
      .from("pickup_requests")
      .update({
        status: "pickup_scheduled",
        tracking_number: cjResult.trackingNumber,
        tracking_carrier: CJ_CARRIER_NAME,
        cj_request_id: cjResult.cjRequestId,
        cj_pickup_registered_at: registeredAt,
        cj_pickup_response: cjResult.rawResponse,
      })
      .eq("id", pickupRequest.id);

    if (updateError) {
      throw updateError;
    }

    await saveLogisticsEvent(supabase, {
      pickup_request_id: pickupRequest.id,
      event_type: "pickup_register",
      status: "success",
      tracking_number: cjResult.trackingNumber,
      payload: cjResult.rawResponse,
    });

    const updatedPickupRequest = await getPickupRequest(supabase, pickupRequest.id);

    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: true,
      status: "registered",
      trackingNumber: cjResult.trackingNumber,
      cjRequestId: cjResult.cjRequestId,
      pickupRequest: updatedPickupRequest,
    };
  } catch (error) {
    await saveLogisticsEvent(supabase, {
      pickup_request_id: pickupRequest.id,
      event_type: "pickup_register",
      status: "failed",
      tracking_number: pickupRequest.tracking_number,
      error_message: getErrorDetail(error),
      payload: error?.responseBody || null,
    });

    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: false,
      status: "failed",
      error: getErrorDetail(error) || "CJ 수거 접수에 실패했습니다.",
      code: error?.code || "CJ_PICKUP_FAILED",
    };
  }
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
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

    let body = {};
    try {
      body = parseJsonBody(req);
    } catch {
      return res.status(400).json(
        makeErrorResponse({
          error: "Invalid JSON body.",
          code: "INVALID_JSON_BODY",
        }),
      );
    }

    const pickupRequestIds = normalizeIds(body.pickupRequestIds ?? body.pickupRequestId);
    if (pickupRequestIds.length === 0) {
      return res.status(400).json(
        makeErrorResponse({
          error: "pickupRequestIds is required.",
          code: "MISSING_PICKUP_REQUEST_IDS",
        }),
      );
    }

    if (pickupRequestIds.length > MAX_BULK_PICKUP_COUNT) {
      return res.status(400).json(
        makeErrorResponse({
          error: `한 번에 최대 ${MAX_BULK_PICKUP_COUNT}건까지 접수할 수 있습니다.`,
          code: "TOO_MANY_PICKUP_REQUESTS",
        }),
      );
    }

    const results = [];
    for (const pickupRequestId of pickupRequestIds) {
      results.push(
        await processPickupRegistration({
          supabase,
          pickupRequestId,
          force: Boolean(body.force),
        }),
      );
    }

    const successCount = results.filter((result) => result.success).length;
    const registeredCount = results.filter((result) => result.status === "registered").length;
    const failedCount = results.filter((result) => !result.success).length;

    return res.status(200).json({
      success: failedCount === 0,
      registeredCount,
      successCount,
      failedCount,
      results,
    });
  } catch (error) {
    const statusCode = error?.statusCode || 500;
    const code =
      statusCode === 401
        ? "AUTH_REQUIRED"
        : statusCode === 403
          ? "ADMIN_REQUIRED"
          : error?.code || error?.message || "CJ_PICKUP_HANDLER_FAILED";

    console.error("[cj-pickup] handler failure", {
      statusCode,
      code,
      message: error?.message || "",
    });

    return res.status(statusCode).json(
      makeErrorResponse({
        error: statusCode === 403 ? "Admin access required." : "CJ pickup request failed.",
        code,
        detail: getErrorDetail(error),
      }),
    );
  }
}
