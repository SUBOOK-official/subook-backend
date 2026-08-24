import { createClient } from "@supabase/supabase-js";

// ──────────────────────────────────────────────────────────────────────────
// CJ대한통운 반품 수거 접수 — 환불 주문의 실물 회수 (구매자 → 수북 입고센터)
//
// 방향이 배송(cj-delivery)의 역: SENDR(발송인)=구매자 배송지, RCVR(수취인)=수북 입고센터.
// 접수 코드는 수거(cj-pickup)와 동일 모델 — RCPT_DV=02(반품), PRT_ST=01(미출력).
// 기사가 운송장을 지참하고 방문하므로 자체 라벨 출력·주소정제(분류코드)가 필요 없다.
//
// 흐름: ReqOneDayToken → ReqInvcNo(채번) → RegBook(예약접수)
//   ORA-00001(중복 접수) 시: CnclBook(유령 예약 취소) → 재채번 → 1회 재접수.
//   ⚠ 접미사 우회 최후수단은 두지 않는다(cj-pickup과 동일) — 반품 수거는 접수만으로
//     기사 출동이 잡히므로, 취소 불가 상태에서 우회 접수하면 이중 출동이 된다.
//
// 프론트 계약:
//   POST /api/admin/cj-return { orderId }                  → 반품 수거 접수
//   POST /api/admin/cj-return { orderId, action: "cancel" [, force] } → 접수 취소
//     (CJ 취소 실패 + force=true면 DB 기록만 비운다 — 기사 스캔 후 등 CJ측 정리 불가 케이스)
// 응답: { success, result: { orderId, trackingNumber, ... } }
//
// CUST_USE_NO = `${order_number}-RT` — 배송 접수(주문번호 그대로)와 키가 겹치지 않게 하고,
// 같은 주문의 반품 재시도는 같은 키가 되어 CJ 유니크 제약이 이중 접수를 막는다(멱등).
// ──────────────────────────────────────────────────────────────────────────

const CJ_REQUEST_TIMEOUT_MS = Number(process.env.CJ_REQUEST_TIMEOUT_MS) || 12_000;
// CJ 운영 서버 콜드 워밍업에서 첫 연결이 자주 끊겨(fetch failed) 여러 번 필요 → 기본 5회.
const CJ_RETRY_COUNT = Number(process.env.CJ_RETRY_COUNT) || 5;
const CJ_CARRIER_NAME = "CJ대한통운";

const DEFAULT_TOKEN_ENDPOINT = "/ReqOneDayToken";
const DEFAULT_INVCNO_ENDPOINT = "/ReqInvcNo";
const DEFAULT_REGBOOK_ENDPOINT = "/RegBook";
const DEFAULT_CNCLBOOK_ENDPOINT = "/CnclBook";

const ORDER_SELECT = `
  id,
  order_number,
  status,
  shipping_recipient_name,
  shipping_recipient_phone,
  shipping_postal_code,
  shipping_address_line1,
  shipping_address_line2,
  item_count,
  refunded_amount,
  return_tracking_number,
  return_cust_use_no,
  return_registered_at,
  order_items (
    id,
    title,
    quantity,
    unit_price,
    refunded_at
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

// CJ 게이트웨이 인증 헤더 — 1Day 토큰 발행은 Key 생략, 업무 API는 토큰을 헤더에 기술 (규격서 p6/p9)
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

function getCjConfig() {
  return {
    baseUrl:
      process.env.CJ_API_BASE_URL ||
      process.env.CJ_LOGISTICS_API_BASE_URL ||
      "",
    tokenEndpoint: process.env.CJ_TOKEN_ENDPOINT || DEFAULT_TOKEN_ENDPOINT,
    invcNoEndpoint: process.env.CJ_INVCNO_ENDPOINT || DEFAULT_INVCNO_ENDPOINT,
    regBookEndpoint: process.env.CJ_REGBOOK_ENDPOINT || DEFAULT_REGBOOK_ENDPOINT,
    cnclBookEndpoint: process.env.CJ_CNCLBOOK_ENDPOINT || DEFAULT_CNCLBOOK_ENDPOINT,

    custId: process.env.CJ_CUST_ID || process.env.CJ_CUSTOMER_ID || "",
    // CJ는 사업자번호를 숫자만으로 조회한다 — 형식 무관 정규화 (cj-pickup과 동일)
    bizRegNum: String(process.env.CJ_BIZ_REG_NUM || "").replace(/\D/g, ""),

    // 수취지 = 수북 입고센터 (env 미설정 시 기본값 사용)
    warehouseName:
      process.env.CJ_WAREHOUSE_NAME || process.env.SUBOOK_WAREHOUSE_NAME || "수북",
    warehousePhone:
      process.env.CJ_WAREHOUSE_PHONE || process.env.SUBOOK_WAREHOUSE_PHONE || "01062715792",
    warehousePostalCode:
      process.env.CJ_WAREHOUSE_POSTAL_CODE || process.env.SUBOOK_WAREHOUSE_POSTAL_CODE || "03722",
    warehouseAddressLine1:
      process.env.CJ_WAREHOUSE_ADDRESS_LINE1 ||
      process.env.SUBOOK_WAREHOUSE_ADDRESS_LINE1 ||
      "서울 서대문구 연세로 50",
    warehouseAddressLine2:
      process.env.CJ_WAREHOUSE_ADDRESS_LINE2 ||
      process.env.SUBOOK_WAREHOUSE_ADDRESS_LINE2 ||
      "연세대학교 212동 경영관 209호 이글루",

    // ── 코드성 필드 (RegBook) — 수거(cj-pickup)와 동일 모델 ─────────────────
    //   RCPT_DV=02(반품, 규격서 p.600행), PRT_ST=01(미출력 — 기사가 운송장 지참),
    //   FRT_DV_CD=03(신용/계약 후불정산), 나머지는 배송·수거 공통 기본값.
    rcptDv: process.env.CJ_RETURN_RCPT_DV || process.env.CJ_RCPT_DV || "02",
    workDvCd: process.env.CJ_WORK_DV_CD || "01",
    reqDvCd: process.env.CJ_REQ_DV_CD || "01",
    calDvCd: process.env.CJ_CAL_DV_CD || "1",
    frtDvCd: process.env.CJ_FRT_DV_CD || "03",
    cntrItemCd: process.env.CJ_CNTR_ITEM_CD || "01",
    boxTypeCd: process.env.CJ_BOX_TYPE_CD || "01",
    prtSt: process.env.CJ_RETURN_PRT_ST || "01",
    codYn: process.env.CJ_COD_YN || "N",
    dlvDv: process.env.CJ_DLV_DV || "01",
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
      const errText = String(normalizedError?.message || normalizedError?.code || "");
      const isNetwork = /fetch failed|ECONN|EAI_AGAIN|socket|network|reset|und_err|terminated|other side closed/i.test(errText);
      if (attempt < CJ_RETRY_COUNT && (isTimeout || isNetwork)) {
        await new Promise((r) => setTimeout(r, 600)); // 짧은 백오프로 연결 warm 유도
        continue;
      }

      throw normalizedError;
    }
  }

  throw lastError || new Error("CJ_API_REQUEST_FAILED");
}

// CJ 응답 래퍼 헬퍼: RESULT_CD가 'S'로 시작하면 성공('S','S200'), 'E'면 실패.
function isCjSuccess(body) {
  return String(body?.RESULT_CD || "").toUpperCase().startsWith("S");
}

function getCjMessage(body) {
  return String(body?.RESULT_DETAIL ?? "").trim();
}

function makeCjBusinessError(body, fallbackCode) {
  const error = new Error(getCjMessage(body) || "CJ API returned an error.");
  error.code = fallbackCode || "CJ_BUSINESS_ERROR";
  error.statusCode = 502;
  error.responseBody = body;
  return error;
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

// 1Day 토큰 발급: { DATA: { CUST_ID, BIZ_REG_NUM } } → DATA.TOKEN_NUM
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
  }, "");

  if (!isCjSuccess(body)) {
    throw makeCjBusinessError(body, "CJ_TOKEN_FAILED");
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

// 채번(운송장번호 생성): { DATA: { CLNTNUM, TOKEN_NUM } } → DATA.INVC_NO
async function reqInvcNo(cfg, token) {
  const body = await postCj(cfg, cfg.invcNoEndpoint, {
    CLNTNUM: cfg.custId,
    TOKEN_NUM: token,
  }, token);

  if (!isCjSuccess(body)) {
    throw makeCjBusinessError(body, "CJ_INVCNO_FAILED");
  }

  const rawInvc = body?.DATA?.INVC_NO;
  const invcNo = String(Array.isArray(rawInvc) ? rawInvc[0]?.INVC_NO ?? rawInvc[0] : rawInvc || "").trim();
  if (!invcNo) {
    const error = new Error("CJ 채번 응답에 INVC_NO가 없습니다.");
    error.code = "CJ_INVCNO_EMPTY";
    error.statusCode = 502;
    error.responseBody = body;
    throw error;
  }

  return invcNo;
}

// 전화번호를 CJ 규격(3분할: NO1/NO2/NO3)으로 분리.
function splitPhone(rawPhone) {
  const digits = String(rawPhone || "").replace(/\D/g, "");
  if (!digits) {
    return { n1: "", n2: "", n3: "" };
  }

  if (digits.startsWith("02")) {
    const rest = digits.slice(2);
    const tail = rest.slice(-4);
    const mid = rest.slice(0, -4);
    return { n1: "02", n2: mid, n3: tail };
  }

  if (digits.length === 11) {
    return { n1: digits.slice(0, 3), n2: digits.slice(3, 7), n3: digits.slice(7) };
  }
  if (digits.length === 10) {
    return { n1: digits.slice(0, 3), n2: digits.slice(3, 6), n3: digits.slice(6) };
  }

  return { n1: digits.slice(0, 3), n2: digits.slice(3, digits.length - 4), n3: digits.slice(-4) };
}

// KST(UTC+9) 기준 YYYYMMDD (서버리스는 UTC로 동작하므로 보정).
function kstYmd(date = new Date()) {
  const kst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10).replace(/-/g, "");
}

// 반품 품목(ARRAY) — 환불된 품목이 있으면 그 품목만, 없으면(선회수) 전체 품목.
function buildGoodsArray(order) {
  const items = Array.isArray(order.order_items) ? order.order_items : [];
  const refunded = items.filter((item) => item.refunded_at);
  const targets = refunded.length > 0 ? refunded : items;
  if (targets.length > 0) {
    return targets.map((item, index) => ({
      MPCK_SEQ: String(index + 1),
      GDS_CD: String(item.id ?? index + 1),
      GDS_NM: String(item.title || "중고 교재").slice(0, 100),
      GDS_QTY: String(Number(item.quantity) || 1),
      UNIT_CD: "EA",
      UNIT_NM: "권",
      GDS_AMT: String(item.unit_price ?? 0),
    }));
  }

  const qty = Number(order.item_count) || 1;
  return [
    {
      MPCK_SEQ: "1",
      GDS_CD: "BOOK",
      GDS_NM: `중고 교재 ${qty}권`,
      GDS_QTY: String(qty),
      UNIT_CD: "EA",
      UNIT_NM: "권",
      GDS_AMT: "0",
    },
  ];
}

// 반품 접수 고객사용번호 — 배송 접수(주문번호 그대로)와 CJ 접수 PK가 겹치지 않게 -RT 접미사.
function returnCustUseNo(orderNumber) {
  return `${orderNumber}-RT`;
}

// 예약접수(RegBook) 바디. 발송인(SENDR)=구매자 배송지, 수취인(RCVR)=수북 입고센터.
function buildRegBookPayload(order, { token, invcNo, cfg }) {
  const buyer = splitPhone(order.shipping_recipient_phone);
  const warehouse = splitPhone(cfg.warehousePhone);
  const custUseNo = returnCustUseNo(order.order_number);

  return {
    CUST_ID: cfg.custId,
    TOKEN_NUM: token,
    RCPT_YMD: kstYmd(),
    CUST_USE_NO: custUseNo,
    RCPT_DV: cfg.rcptDv,
    WORK_DV_CD: cfg.workDvCd,
    REQ_DV_CD: cfg.reqDvCd,
    MPCK_KEY: custUseNo,
    CAL_DV_CD: cfg.calDvCd,
    FRT_DV_CD: cfg.frtDvCd,
    CNTR_ITEM_CD: cfg.cntrItemCd,
    BOX_TYPE_CD: cfg.boxTypeCd,
    BOX_QTY: "1", // 반품 회수는 주문당 1박스
    FRT: "0",
    CUST_MGMT_DLCM_CD: cfg.custId,

    // 발송인 = 구매자 (회수 대상 — 배송의 수취인이 역방향으로 발송인이 된다)
    SENDR_NM: order.shipping_recipient_name || "",
    SENDR_TEL_NO1: buyer.n1,
    SENDR_TEL_NO2: buyer.n2,
    SENDR_TEL_NO3: buyer.n3,
    SENDR_CELL_NO1: buyer.n1,
    SENDR_CELL_NO2: buyer.n2,
    SENDR_CELL_NO3: buyer.n3,
    SENDR_ZIP_NO: order.shipping_postal_code || "",
    SENDR_ADDR: order.shipping_address_line1 || "",
    // 상세주소 미입력 대응 — CJ Oracle은 빈 문자열을 NULL로 취급해 ORA-01400으로 접수를 거부한다.
    SENDR_DETAIL_ADDR: String(order.shipping_address_line2 || "").trim() || "-",

    // 수취인 = 수북 입고센터
    RCVR_NM: cfg.warehouseName,
    RCVR_TEL_NO1: warehouse.n1,
    RCVR_TEL_NO2: warehouse.n2,
    RCVR_TEL_NO3: warehouse.n3,
    RCVR_CELL_NO1: warehouse.n1,
    RCVR_CELL_NO2: warehouse.n2,
    RCVR_CELL_NO3: warehouse.n3,
    RCVR_ZIP_NO: cfg.warehousePostalCode,
    RCVR_ADDR: cfg.warehouseAddressLine1,
    RCVR_DETAIL_ADDR: cfg.warehouseAddressLine2,

    // 주문자 = 수북 (반품 회수 요청 주체)
    ORDRR_NM: cfg.warehouseName,
    ORDRR_TEL_NO1: warehouse.n1,
    ORDRR_TEL_NO2: warehouse.n2,
    ORDRR_TEL_NO3: warehouse.n3,
    ORDRR_CELL_NO1: warehouse.n1,
    ORDRR_CELL_NO2: warehouse.n2,
    ORDRR_CELL_NO3: warehouse.n3,
    ORDRR_ZIP_NO: cfg.warehousePostalCode,
    ORDRR_ADDR: cfg.warehouseAddressLine1,
    ORDRR_DETAIL_ADDR: cfg.warehouseAddressLine2,

    INVC_NO: invcNo,
    COLCT_EXPCT_YMD: kstYmd(), // 집화(회수) 예정일 = 오늘
    PRT_ST: cfg.prtSt,
    ARTICLE_AMT: "0",
    REMARK_1: `[반품 회수] 주문 ${order.order_number}`.slice(0, 100),
    COD_YN: cfg.codYn,
    DLV_DV: cfg.dlvDv,
    ARRAY: buildGoodsArray(order),
  };
}

// CJ Oracle unique 제약 위반(= 같은 접수 키로 이미 예약이 존재) 감지.
function isCjDuplicateBooking(body) {
  return /ORA-00001|unique constraint/i.test(getCjMessage(body));
}

// 예약취소(CnclBook) 바디 — 접수 바디와 동일 구조에 REQ_DV_CD=02(취소), 대상 접수일자 지정.
// CUST_USE_NO가 `-RT` 키라 같은 주문의 배송(발송) 예약은 건드리지 않는다.
function buildCancelPayload(order, { token, cfg, rcptYmd, custUseNo = "" }) {
  const payload = {
    ...buildRegBookPayload(order, { token, invcNo: "", cfg }),
    RCPT_YMD: rcptYmd,
    REQ_DV_CD: "02",
  };
  if (custUseNo) {
    payload.CUST_USE_NO = custUseNo;
    payload.MPCK_KEY = custUseNo;
  }
  delete payload.INVC_NO;
  return payload;
}

// 유령 예약(응답 유실로 우리 DB에 기록되지 못한 CJ 접수) 취소 — 오늘~D-2 순차 시도.
// 대상 없는 날짜는 CJ가 E로 응답 — 무해. 실패해도 던지지 않는다(이후 재접수가 최종 판정).
async function cancelStrayBookings(order, { token, cfg }) {
  const results = [];
  for (let daysAgo = 0; daysAgo <= 2; daysAgo += 1) {
    const rcptYmd = kstYmd(new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000));
    try {
      const body = await postCj(
        cfg,
        cfg.cnclBookEndpoint,
        buildCancelPayload(order, { token, cfg, rcptYmd }),
        token,
      );
      results.push({ rcptYmd, ok: isCjSuccess(body), detail: getCjMessage(body).slice(0, 200) });
    } catch (error) {
      results.push({ rcptYmd, ok: false, detail: String(error?.message || "").slice(0, 200) });
    }
  }
  return results;
}

function makeMockTrackingNumber(order) {
  const nowDigits = kstYmd().slice(2) + String(Date.now()).slice(-4);
  const idDigits = String(order.id || 0).padStart(6, "0").slice(-6);
  return `${nowDigits}${idDigits}`.slice(-12).padStart(12, "0");
}

async function registerCjReturn(order, { token, cfg }) {
  const custUseNo = returnCustUseNo(order.order_number);

  if (isMockMode()) {
    const trackingNumber = makeMockTrackingNumber(order);
    return {
      trackingNumber,
      custUseNo,
      rawResponse: { mock: true, RESULT_CD: "S", trackingNumber },
    };
  }

  // 1) 채번 → 운송장번호 확보 (기사 방문 접수라 자체 라벨·주소정제 불필요)
  let invcNo = await reqInvcNo(cfg, token);

  // 2) 예약접수 (헤더 키 = 토큰)
  let body = await postCj(cfg, cfg.regBookEndpoint, buildRegBookPayload(order, { token, invcNo, cfg }), token);
  let healed = null;

  // ORA-00001(중복 접수) 자동 복구 — 유령 예약 취소 후 새 번호로 1회 재접수.
  // 접미사 우회는 없음(이중 기사 출동 위험 — cj-pickup과 동일 정책).
  if (!isCjSuccess(body) && isCjDuplicateBooking(body)) {
    console.warn("[cj-return] duplicate booking — auto-heal start", {
      custUseNo,
      detail: getCjMessage(body).slice(0, 200),
    });
    const cancelResults = await cancelStrayBookings(order, { token, cfg });
    console.warn("[cj-return] stray cancel results", { custUseNo, cancelResults });

    invcNo = await reqInvcNo(cfg, token);
    body = await postCj(cfg, cfg.regBookEndpoint, buildRegBookPayload(order, { token, invcNo, cfg }), token);
    healed = "cancel-reregister";
  }

  if (!isCjSuccess(body)) {
    const error = makeCjBusinessError(body, "CJ_REGBOOK_FAILED");
    if (healed && isCjDuplicateBooking(body)) {
      error.message = `CJ에 같은 접수번호(${custUseNo})의 반품 예약이 남아 있는데 취소가 불가한 상태입니다 (${getCjMessage(body)}). 기사 배정/스캔이 이미 진행됐을 수 있으니 이중 접수하지 말고, CJ 지점 문의로 기존 접수 상태를 확인해 주세요.`;
    }
    throw error;
  }

  // 성공 즉시 운송장번호 로그 — 응답 유실·DB 기록 실패 시 복구 근거.
  console.log("[cj-return] regbook ok", { custUseNo, invcNo, healed });

  return {
    trackingNumber: invcNo,
    custUseNo,
    healed,
    rawResponse: body,
  };
}

function getErrorDetail(error) {
  const responseDetail = error?.responseBody
    ? JSON.stringify(error.responseBody).slice(0, 500)
    : "";
  return responseDetail || String(error?.message || "").slice(0, 500);
}

async function getOrder(supabase, orderId) {
  const { data, error } = await supabase
    .from("orders")
    .select(ORDER_SELECT)
    .eq("id", orderId)
    .maybeSingle();

  if (error) {
    throw error;
  }

  return data;
}

// 반품 수거 접수 가능: 실물이 구매자에게 있(었)을 상태 — 배송중 이후 또는 (부분)환불된 주문.
function canRegisterReturn(order) {
  return (
    ["shipping", "delivered", "confirmed", "refunded"].includes(order.status) ||
    Number(order.refunded_amount ?? 0) > 0
  );
}

async function handleRegister({ supabase, order, token, cfg }) {
  if (order.return_tracking_number) {
    return {
      status: 200,
      body: {
        success: true,
        result: {
          orderId: order.id,
          orderNumber: order.order_number,
          status: "skipped",
          trackingNumber: order.return_tracking_number,
          carrier: CJ_CARRIER_NAME,
        },
      },
    };
  }

  if (!canRegisterReturn(order)) {
    return {
      status: 409,
      body: makeErrorResponse({
        error: `현재 상태(${order.status})에서는 반품 수거를 접수할 수 없습니다 — 배송중 이후 또는 환불된 주문만 가능합니다.`,
        code: "INVALID_ORDER_STATUS",
      }),
    };
  }

  if (!order.shipping_address_line1 || !order.shipping_recipient_phone) {
    return {
      status: 409,
      body: makeErrorResponse({
        error: "주문에 배송지 주소/연락처가 없어 반품 수거를 접수할 수 없습니다.",
        code: "MISSING_SHIPPING_ADDRESS",
      }),
    };
  }

  const cjResult = await registerCjReturn(order, { token, cfg });

  const { error: updateError } = await supabase
    .from("orders")
    .update({
      return_tracking_number: cjResult.trackingNumber,
      return_cust_use_no: cjResult.custUseNo,
      return_registered_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", order.id);

  if (updateError) {
    // CJ 접수는 이미 성공 — 기록 실패를 조용히 삼키면 유령 예약이 된다. 위 regbook ok 로그가 복구 근거.
    console.error("[cj-return] CRITICAL: CJ 접수 성공 후 DB 기록 실패", {
      orderNumber: order.order_number,
      trackingNumber: cjResult.trackingNumber,
      error: updateError.message,
    });
    return {
      status: 500,
      body: makeErrorResponse({
        error: `CJ 반품 접수(운송장 ${cjResult.trackingNumber})는 성공했으나 DB 기록에 실패했습니다. 같은 버튼으로 다시 시도하면 자동 복구됩니다.`,
        code: "RETURN_DB_UPDATE_FAILED",
      }),
    };
  }

  return {
    status: 200,
    body: {
      success: true,
      result: {
        orderId: order.id,
        orderNumber: order.order_number,
        status: "registered",
        trackingNumber: cjResult.trackingNumber,
        carrier: CJ_CARRIER_NAME,
        healed: cjResult.healed || null,
      },
    },
  };
}

async function handleCancel({ supabase, order, token, cfg, force }) {
  if (!order.return_tracking_number && !order.return_cust_use_no) {
    return {
      status: 409,
      body: makeErrorResponse({
        error: "접수된 반품 수거가 없습니다.",
        code: "RETURN_NOT_REGISTERED",
      }),
    };
  }

  const custUseNo = order.return_cust_use_no || returnCustUseNo(order.order_number);
  let cjCancelled = false;
  let cancelDetail = "";

  if (isMockMode()) {
    cjCancelled = true;
  } else {
    // 접수일자(RCPT_YMD)가 CJ 접수 PK의 일부 — 기록된 접수 시각의 KST 날짜로 정확히 매칭.
    const rcptYmd = order.return_registered_at
      ? kstYmd(new Date(order.return_registered_at))
      : kstYmd();
    try {
      const body = await postCj(
        cfg,
        cfg.cnclBookEndpoint,
        buildCancelPayload(order, { token, cfg, rcptYmd, custUseNo }),
        token,
      );
      cjCancelled = isCjSuccess(body);
      cancelDetail = getCjMessage(body).slice(0, 300);
    } catch (error) {
      cancelDetail = String(error?.message || "").slice(0, 300);
    }
  }

  if (!cjCancelled && !force) {
    return {
      status: 502,
      body: makeErrorResponse({
        error:
          `CJ 반품 예약 취소가 거부되었습니다${cancelDetail ? ` (${cancelDetail})` : ""}. ` +
          "기사 배정/스캔이 진행됐을 수 있습니다 — CJ 지점 확인 후, DB 기록만 지우려면 '기록만 삭제'로 다시 시도하세요.",
        code: "CJ_CANCEL_FAILED",
      }),
    };
  }

  const { error: updateError } = await supabase
    .from("orders")
    .update({
      return_tracking_number: null,
      return_cust_use_no: null,
      return_registered_at: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", order.id);

  if (updateError) {
    return {
      status: 500,
      body: makeErrorResponse({
        error: `CJ 예약 취소${cjCancelled ? "는 성공했으나" : " 없이"} DB 기록 삭제에 실패했습니다: ${updateError.message}`,
        code: "RETURN_DB_UPDATE_FAILED",
      }),
    };
  }

  return {
    status: 200,
    body: {
      success: true,
      result: {
        orderId: order.id,
        orderNumber: order.order_number,
        status: "cancelled",
        cjCancelled,
        dbOnly: !cjCancelled,
      },
    },
  };
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json(
      makeErrorResponse({ error: "Method not allowed.", code: "METHOD_NOT_ALLOWED" }),
    );
  }

  const accessToken = parseBearerToken(req.headers.authorization);
  if (!accessToken) {
    return res.status(401).json(
      makeErrorResponse({ error: "Missing authorization token.", code: "MISSING_AUTH_TOKEN" }),
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
        makeErrorResponse({ error: "Invalid JSON body.", code: "INVALID_JSON_BODY" }),
      );
    }

    const orderId = Number.parseInt(String(body.orderId), 10);
    if (!Number.isInteger(orderId) || orderId <= 0) {
      return res.status(400).json(
        makeErrorResponse({ error: "orderId is required.", code: "MISSING_ORDER_ID" }),
      );
    }

    const order = await getOrder(supabase, orderId);
    if (!order) {
      return res.status(404).json(
        makeErrorResponse({ error: "주문을 찾을 수 없습니다.", code: "ORDER_NOT_FOUND" }),
      );
    }

    const cfg = getCjConfig();
    const token = await getOneDayToken(cfg);
    const action = String(body.action || "register");

    const outcome =
      action === "cancel"
        ? await handleCancel({ supabase, order, token, cfg, force: Boolean(body.force) })
        : await handleRegister({ supabase, order, token, cfg });

    return res.status(outcome.status).json(outcome.body);
  } catch (error) {
    const statusCode = error?.statusCode || 500;
    const code =
      statusCode === 401
        ? "AUTH_REQUIRED"
        : statusCode === 403
          ? "ADMIN_REQUIRED"
          : error?.code || error?.message || "CJ_RETURN_HANDLER_FAILED";

    console.error("[cj-return] handler failure", {
      statusCode,
      code,
      message: error?.message || "",
    });

    return res.status(statusCode).json(
      makeErrorResponse({
        error: statusCode === 403 ? "Admin access required." : "CJ return request failed.",
        code,
        detail: getErrorDetail(error),
      }),
    );
  }
}
