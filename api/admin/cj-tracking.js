import { createClient } from "@supabase/supabase-js";

// ──────────────────────────────────────────────────────────────────────────
// CJ대한통운 Open API (택배 표준 API) — 배송(집화) 추적
//
// 흐름: ReqOneDayToken(1Day 토큰) → ReqOneGdsTrc(운송장번호 기준 단건 추적)
// 인증: 헤더 CJ-Gateway-APIKey + 바디 DATA.TOKEN_NUM
// 응답 DATA: [ { CRG_ST(상태코드), CRG_ST_NM(상태명), SCAN_YMD, SCAN_HOUR,
//               DEALT_BRAN_NM(담당점소), INVC_NO, ACPTR_NM(인수자) }, ... ]
// 규격: 개발자포털 자료실 "CJLAPI-택배 표준 API Developer Guide" (V3.9.4) 기준
//
// 멀티박스(2026-08-08 개편): 수거 요청은 박스당 운송장 1장(pickup_requests.box_waybills).
// pickupRequestId 조회 시 대표 운송장(box1)만이 아니라 박스별 전체 운송장을 조회해
// 집계하고, 요청 상태 전환은 보수적으로 — arrived/cancelled는 전 박스(미접수 박스
// 포함) 판정이 일치할 때만 넘긴다. cj_tracking_status에는 박스별 현황 요약을 저장.
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
  box_count,
  box_waybills,
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
    // ⚠ CJ는 사업자번호를 숫자만으로 조회 — 하이픈 포함 시 "고객사코드가 존재하지
    //   않습니다" 오해성 에러(2026-07-03 실측). 형식 무관 정규화.
    bizRegNum: String(process.env.CJ_BIZ_REG_NUM || "").replace(/\D/g, ""),
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

// ⚠ 규격서 V3.9.4 p6/p9: 헤더 CJ-Gateway-APIKey — 토큰 발행은 Key 생략,
// 그 외 업무 API는 발급받은 "1Day 토큰"과 동일 값을 헤더에 기술.
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

async function postCj(cfg, endpoint, data, apiKey) {
  if (!cfg.baseUrl) {
    const error = new Error("CJ_API_BASE_URL is required. Set CJ_LOGISTICS_MOCK=true for local mock mode.");
    error.code = "CJ_CONFIG_MISSING";
    error.statusCode = 500;
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
    error.statusCode = 500;
    throw error;
  }

  // 토큰 발행은 헤더 Key 생략 (규격서 p6)
  const body = await postCj(cfg, cfg.tokenEndpoint, {
    CUST_ID: cfg.custId,
    BIZ_REG_NUM: cfg.bizRegNum,
  }, "");

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

// cfg/token을 넘기면 재사용(멀티박스 — 토큰은 요청당 1회 발급), 없으면 자체 발급(단건 직접 조회).
async function fetchCjTracking(waybillNo, { cfg, token } = {}) {
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

  const effectiveCfg = cfg || getCjConfig();
  const effectiveToken = token || (await getOneDayToken(effectiveCfg));

  // 업무 API: 헤더 CJ-Gateway-APIKey = 1Day 토큰 (규격서 p6/p9)
  const body = await postCj(effectiveCfg, effectiveCfg.trackingEndpoint, {
    CLNTNUM: effectiveCfg.custId,
    INVC_NO: waybillNo,
    TOKEN_NUM: effectiveToken,
  }, effectiveToken);

  if (!isCjSuccess(body)) {
    const message = getCjMessage(body);
    // 채번 직후 ~ 집화 스캔 전에는 추적 데이터가 원래 없다 (cj-delivery-tracking.js와 동일
    // 실측). 에러가 아니라 "아직 없음"으로 취급해야 멀티박스 집계가 박스 하나 때문에
    // 통째로 실패하지 않는다. ⚠ 이 statusText에 "집화" 같은 매핑 키워드가 들어가므로
    // 상태 매핑 전에 noData를 먼저 걸러야 한다(aggregatePickupMappedStatus 참고).
    if (/no data/i.test(message)) {
      return {
        waybillNo,
        carrier: CJ_CARRIER_NAME,
        statusCode: null,
        statusText: "추적 데이터 없음(집화 스캔 전)",
        noData: true,
        events: [],
        rawResponse: body,
      };
    }
    const error = new Error(message || "CJ 배송 추적 조회에 실패했습니다.");
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

// 박스별 운송장 기록 정규화 (cj-pickup.js와 동일 규칙). 멀티박스 도입(2026-08) 전
// 접수분(레거시)은 box_waybills가 비어 있으므로 tracking_number 존재 시 1번 박스
// 접수분으로 간주한다 — 이 합성 엔트리는 조회용일 뿐 DB에 되쓰지 않는다.
function normalizeBoxWaybills(pickupRequest) {
  const raw = Array.isArray(pickupRequest.box_waybills) ? pickupRequest.box_waybills : [];
  const entries = raw
    .map((entry) => ({
      box_seq: Number(entry?.box_seq),
      tracking_number: normalizeTrackingNumber(entry?.tracking_number),
    }))
    .filter((entry) => Number.isInteger(entry.box_seq) && entry.box_seq >= 1 && entry.tracking_number);

  if (entries.length === 0 && pickupRequest.tracking_number) {
    entries.push({
      box_seq: 1,
      tracking_number: normalizeTrackingNumber(pickupRequest.tracking_number),
    });
  }

  return entries
    .filter((entry) => entry.tracking_number)
    .sort((a, b) => a.box_seq - b.box_seq);
}

// 박스별 CJ 상태 → 요청 단위 상태 집계 (보수적 전환 규칙, 2026-08-08 멀티박스 개편).
// - arrived/cancelled처럼 "전량" 판정이 필요한 전환은 모든 박스(미접수 박스 포함)의
//   판정이 일치할 때만 허용 — 일부만 입고돼도 arrived로 넘기지 않는다.
// - 조회 실패·집화 스캔 전(noData) 박스는 판정 불명으로 취급해 전량 판정을 막는다.
// - 일부 박스만 취소/반송된 혼합 케이스는 자동 전환하지 않는다(운영자 판단 영역).
function aggregatePickupMappedStatus(boxResults, unregisteredBoxes) {
  const mapped = boxResults.map((box) =>
    box.failed || box.noData ? null : mapTrackingToPickupStatus(box),
  );
  const known = mapped.filter(Boolean);
  if (known.length === 0) {
    return null;
  }

  const everyBoxKnown = unregisteredBoxes === 0 && mapped.every(Boolean);
  if (everyBoxKnown && mapped.every((status) => status === "arrived")) {
    return "arrived";
  }
  if (everyBoxKnown && mapped.every((status) => status === "cancelled")) {
    return "cancelled";
  }
  if (known.some((status) => status === "picking_up" || status === "arrived")) {
    return "picking_up";
  }
  if (known.some((status) => status === "pickup_scheduled")) {
    return "pickup_scheduled";
  }
  return null;
}

function buildBoxStatusLabel(box) {
  if (box.failed) {
    return "조회 실패";
  }
  return box.statusText || "상태 미확인";
}

// cj_tracking_status 저장·표시 문자열. 단일 박스는 기존처럼 상태명만, 멀티박스는
// "박스1 배송완료 · 박스2 집화처리 · 미접수 1박스"처럼 박스별 현황을 그대로 노출한다.
function buildStatusSummary(boxResults, unregisteredBoxes, isMultibox) {
  if (!isMultibox) {
    return buildBoxStatusLabel(boxResults[0]);
  }

  const parts = boxResults.map((box) => `박스${box.boxSeq} ${buildBoxStatusLabel(box)}`);
  if (unregisteredBoxes > 0) {
    parts.push(`미접수 ${unregisteredBoxes}박스`);
  }
  return parts.join(" · ");
}

// 박스별 조회 결과를 box_waybills 엔트리에 병합. 조회 실패한 박스는 마지막으로 성공한
// 상태를 유지하고(덮어쓰지 않음), 기존 필드(cust_use_no·백필 주석 등)는 그대로 보존한다.
function mergeBoxTrackingIntoWaybills(rawBoxWaybills, boxResults, checkedAt) {
  const resultBySeq = new Map(boxResults.map((box) => [box.boxSeq, box]));
  return rawBoxWaybills.map((entry) => {
    const result = resultBySeq.get(Number(entry?.box_seq));
    if (!result || result.failed) {
      return entry;
    }
    return {
      ...entry,
      tracking_status: result.statusText || null,
      tracking_status_code: result.statusCode ?? null,
      tracking_checked_at: checkedAt,
    };
  });
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

    // 단건 직접 조회 (수거 요청 없이 운송장만) — DB 미반영, 기존 동작 유지.
    if (!pickupRequest) {
      if (!directWaybillNo) {
        return res.status(400).json(
          makeErrorResponse({
            error: "waybillNo 또는 pickupRequestId의 운송장이 필요합니다.",
            code: "MISSING_WAYBILL_NO",
          }),
        );
      }

      const tracking = await fetchCjTracking(directWaybillNo);
      return res.status(200).json({ success: true, tracking, pickupRequest: null });
    }

    // 수거 요청 조회 — 박스별 운송장 전체를 추적한다 (대표 box1만 보던 구조 폐지).
    const boxTargets = normalizeBoxWaybills(pickupRequest);
    if (boxTargets.length === 0 && directWaybillNo) {
      boxTargets.push({ box_seq: 1, tracking_number: directWaybillNo });
    }

    if (boxTargets.length === 0) {
      return res.status(400).json(
        makeErrorResponse({
          error: "waybillNo 또는 pickupRequestId의 운송장이 필요합니다.",
          code: "MISSING_WAYBILL_NO",
        }),
      );
    }

    // 토큰은 요청당 1회 발급해 박스별 조회에 재사용 (1Day 토큰 — 규격서 p6)
    const cfg = getCjConfig();
    const token = await getOneDayToken(cfg);

    const boxResults = [];
    let firstLookupError = null;
    for (const target of boxTargets) {
      try {
        const result = await fetchCjTracking(target.tracking_number, { cfg, token });
        boxResults.push({ boxSeq: target.box_seq, ...result });
      } catch (error) {
        // 일부 박스 실패는 배치를 끊지 않는다 — 남은 박스 현황이라도 집계·표시.
        if (!firstLookupError) {
          firstLookupError = error;
        }
        boxResults.push({
          boxSeq: target.box_seq,
          waybillNo: target.tracking_number,
          carrier: CJ_CARRIER_NAME,
          statusCode: null,
          statusText: "조회 실패",
          events: [],
          failed: true,
          error: getErrorDetail(error),
        });
      }
    }

    // 전 박스 조회 실패면 기존 단일 조회와 동일하게 에러 응답 (DB 미반영).
    if (boxResults.every((box) => box.failed)) {
      throw firstLookupError || new Error("CJ 배송 추적 조회에 실패했습니다.");
    }

    const checkedAt = new Date().toISOString();
    const totalBoxes = Math.max(1, Number(pickupRequest.box_count) || 1, boxTargets.length);
    const unregisteredBoxes = Math.max(0, totalBoxes - boxTargets.length);
    const isMultibox = boxTargets.length > 1 || unregisteredBoxes > 0;

    const mappedStatus = aggregatePickupMappedStatus(boxResults, unregisteredBoxes);
    const nextStatus = chooseNextPickupStatus(pickupRequest.status, mappedStatus);

    const statusSummary = buildStatusSummary(boxResults, unregisteredBoxes, isMultibox);
    const statusCodes = [...new Set(boxResults.map((box) => box.statusCode).filter(Boolean))];
    const aggregateStatusCode = statusCodes.length === 1 ? statusCodes[0] : null;

    // 이력은 박스 순서대로 이어붙이고, 멀티박스면 이벤트에 boxSeq를 남긴다.
    const combinedEvents = boxResults.flatMap((box) =>
      (box.events || []).map((event) => (isMultibox ? { ...event, boxSeq: box.boxSeq } : event)),
    );

    // 대표 운송장(단일 컬럼)은 기존 값 우선, 없으면 box1로 자가 복구.
    const box1Target = boxTargets.find((target) => target.box_seq === 1);
    const representativeWaybillNo =
      normalizeTrackingNumber(pickupRequest.tracking_number) ||
      box1Target?.tracking_number ||
      boxTargets[0].tracking_number;

    const update = {
      status: nextStatus,
      tracking_number: representativeWaybillNo,
      tracking_carrier: CJ_CARRIER_NAME,
      cj_tracking_status: statusSummary,
      cj_tracking_status_code: aggregateStatusCode,
      cj_tracking_last_checked_at: checkedAt,
      cj_tracking_history: combinedEvents,
      cj_tracking_response: isMultibox
        ? {
            multibox: true,
            boxes: boxResults.map((box) => ({
              box_seq: box.boxSeq,
              response: box.rawResponse ?? null,
              error: box.error ?? null,
            })),
          }
        : boxResults[0].rawResponse ?? null,
    };

    // 박스별 최신 상태를 box_waybills 엔트리에도 병합 — 상세 화면의 박스별 현황 소스.
    // 레거시 행(배열 비어 있음)은 합성 엔트리를 되쓰지 않고 기존 컬럼만 갱신한다.
    const rawBoxWaybills = Array.isArray(pickupRequest.box_waybills)
      ? pickupRequest.box_waybills
      : [];
    if (rawBoxWaybills.length > 0) {
      update.box_waybills = mergeBoxTrackingIntoWaybills(rawBoxWaybills, boxResults, checkedAt);
    }

    const { error: updateError } = await supabase
      .from("pickup_requests")
      .update(update)
      .eq("id", pickupRequest.id);

    if (updateError) {
      throw updateError;
    }

    for (const box of boxResults) {
      await saveLogisticsEvent(supabase, {
        pickup_request_id: pickupRequest.id,
        event_type: "tracking_lookup",
        status: box.failed ? "failed" : "success",
        tracking_number: box.waybillNo,
        status_code: box.statusCode,
        status_text: box.statusText,
        error_message: box.failed ? box.error : null,
        payload: isMultibox
          ? { box_seq: box.boxSeq, response: box.rawResponse ?? null }
          : box.rawResponse ?? null,
      });
    }

    const updatedPickupRequest = await getPickupRequest(supabase, pickupRequest.id);

    return res.status(200).json({
      success: true,
      tracking: {
        waybillNo: representativeWaybillNo,
        carrier: CJ_CARRIER_NAME,
        statusCode: aggregateStatusCode,
        statusText: statusSummary,
        events: combinedEvents,
        // 박스별 상세 (rawResponse 제외 — 응답 슬림화). UI는 boxes가 2개 이상일 때
        // 박스별 섹션으로 렌더링한다.
        boxes: boxResults.map(({ rawResponse, ...box }) => box),
        totalBoxes,
        registeredBoxes: boxTargets.length,
        unregisteredBoxes,
      },
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
