import { createClient } from "@supabase/supabase-js";

// ──────────────────────────────────────────────────────────────────────────
// CJ대한통운 Open API (택배 표준 API) — 배송(발송) 예약 접수 + 자체 운송장 발급
//
// 흐름: ReqOneDayToken(1Day 토큰) → ReqInvcNo(채번=운송장번호) → RegBook(예약접수)
// 인증: 헤더 CJ-Gateway-APIKey = 1Day 토큰 (규격서 V3.9.4 p6/p9). 바디 DATA.TOKEN_NUM 동일 값.
// 환경: 테스트 https://dxapi-dev.cjlogistics.com:5054 / 운영 https://dxapi.cjlogistics.com:5052
//
// 수북 배송 모델 = 수북 입고센터(SENDR, 발송인) → 구매자(RCVR, 수취인). 고객사 자체 출력이라
//   채번으로 운송장번호를 확보하고, 그 번호로 admin에서 표준 운송장 라벨을 출력한다.
// 프론트 계약: POST /api/admin/cj-delivery {orderId|orderIds} → {results:[{orderId,trackingNumber,...}]}
// 응답 래퍼: { "RESULT_CD":"S"|"S200"(성공) | "E"|"E4xx"(실패), "RESULT_DETAIL":..., "DATA":{...} }
// ──────────────────────────────────────────────────────────────────────────

const CJ_REQUEST_TIMEOUT_MS = Number(process.env.CJ_REQUEST_TIMEOUT_MS) || 12_000;
// CJ 운영 서버 콜드 워밍업에서 첫 연결이 자주 끊겨(fetch failed) 여러 번 필요 → 기본 5회.
const CJ_RETRY_COUNT = Number(process.env.CJ_RETRY_COUNT) || 5;
const MAX_BULK_DELIVERY_COUNT = 30;
const CJ_CARRIER_NAME = "CJ대한통운";

const DEFAULT_TOKEN_ENDPOINT = "/ReqOneDayToken";
const DEFAULT_INVCNO_ENDPOINT = "/ReqInvcNo";
const DEFAULT_REGBOOK_ENDPOINT = "/RegBook";
const DEFAULT_ADDR_ENDPOINT = "/ReqAddrRfnSm";

const ORDER_SELECT = `
  id,
  user_id,
  order_number,
  status,
  shipping_recipient_name,
  shipping_recipient_phone,
  shipping_postal_code,
  shipping_address_line1,
  shipping_address_line2,
  shipping_memo,
  item_count,
  total_amount,
  tracking_number,
  tracking_carrier,
  auto_confirm_at,
  created_at,
  updated_at,
  order_items (
    id,
    title,
    option_label,
    quantity,
    unit_price
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

// CJ 게이트웨이 인증 헤더.
// ⚠ 규격서 V3.9.4 p6/p9 확정: 헤더 CJ-Gateway-APIKey 값 규칙 —
//   · 1Day 토큰 발행(ReqOneDayToken): Key 생략
//   · 그 외 업무 API: ReqOneDayToken이 발급한 "1Day 토큰"과 동일 값을 헤더에 기술
// (2026-07-04까지는 규격서의 예시 게이트웨이키를 넣어 업무 API가 전부 401 인증실패였음.
//  2026-07-05 규격서 확인 후 채번(ReqInvcNo) 200 성공으로 검증됨 → CJ 승인 문제 아니었음.)
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
    addrEndpoint: process.env.CJ_ADDR_ENDPOINT || DEFAULT_ADDR_ENDPOINT,

    // 고객사코드(CUST_ID/CLNTNUM) + 사업자등록번호(토큰 발급에 필요) — 계약 후 발급
    custId: process.env.CJ_CUST_ID || process.env.CJ_CUSTOMER_ID || "",
    // ⚠ CJ는 사업자번호를 숫자만으로 조회한다. 하이픈 포함 시 "입력하신 고객사코드가
    //   존재하지 않습니다"라는 오해성 에러가 난다(2026-07-03 실측) — 형식 무관 정규화.
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

    // ── 코드성 필드 (RegBook) ──────────────────────────────────────────────
    // CJ 규격서 샘플 기준 기본값. 한글 코드표가 PDF 폰트 문제로 추출되지 않아,
    // 정확한 집화/운임 코드는 계약·테스트 시 CJ 확인 후 env로 조정한다.
    //   RCPT_DV 접수구분(02=방문집화 추정), FRT_DV_CD 운임구분(03=신용/계약),
    //   CAL_DV_CD 정산구분, CNTR_ITEM_CD 품목, BOX_TYPE_CD 박스규격,
    //   PRT_ST 출력상태, COD_YN 착불여부, DLV_DV 배송구분, WORK_DV_CD 작업구분.
    // 배송(발송)은 일반 접수 → RCPT_DV=01 (수거/반품·회수의 02와 다름, 규격서 p32). env로 조정 가능.
    rcptDv: process.env.CJ_DELIVERY_RCPT_DV || "01",
    workDvCd: process.env.CJ_WORK_DV_CD || "01",
    reqDvCd: process.env.CJ_REQ_DV_CD || "01",
    calDvCd: process.env.CJ_CAL_DV_CD || "1",
    frtDvCd: process.env.CJ_FRT_DV_CD || "03",
    cntrItemCd: process.env.CJ_CNTR_ITEM_CD || "01",
    boxTypeCd: process.env.CJ_BOX_TYPE_CD || "02",
    prtSt: process.env.CJ_PRT_ST || "02",
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
      // "fetch failed"(연결 실패/리셋 등) — CJ 운영 콜드 워밍업에서 흔한 케이스. 재시도로 관통.
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

  // 토큰 발행은 헤더 Key 생략 (규격서 p6)
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
  // 업무 API: 헤더 CJ-Gateway-APIKey = 1Day 토큰 (규격서 p6/p9)
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

// 주소정제(ReqAddrRfnSm): 라벨 라우팅 데이터(분류코드/주소약칭/배송점소/P2P) 확보.
// 실패해도 배송접수는 계속 진행 — 라벨 라우팅 데이터만 비게 두고 운영자가 재시도/보정.
async function reqAddrRefine(cfg, token, address) {
  try {
    const body = await postCj(cfg, cfg.addrEndpoint, {
      CLNTNUM: cfg.custId,
      CLNTMGMCUSTCD: cfg.custId,
      ADDRESS: String(address || "").trim(),
      TOKEN_NUM: token,
    }, token);
    if (!isCjSuccess(body)) {
      return null;
    }
    const d = body?.DATA || {};
    return {
      clsfCd: d.CLSFCD ?? null, // 분류코드(대분류)
      subClsfCd: d.SUBCLSFCD ?? null, // 서브코드
      clsfAddr: d.CLSFADDR ?? null, // 주소약칭
      clldlvBranNm: d.CLLDLVBRANNM ?? null, // 배송집배점명
      clldlvEmpNickNm: d.CLLDLVEMPNICKNM ?? null, // 배송사원 별칭(권역)
      rspsDiv: d.RSPSDIV ?? null, // 전담권역
      p2pCd: d.P2PCD ?? null, // 권내배송코드
    };
  } catch (error) {
    console.error("[cj-delivery] addr refine failed", error?.message);
    return null;
  }
}

// 주소정제 입력용 전체 주소 문자열.
function buildFullAddress(order) {
  return [order.shipping_address_line1, order.shipping_address_line2]
    .map((s) => String(s || "").trim())
    .filter(Boolean)
    .join(" ");
}

// 전화번호를 CJ 규격(3분할: NO1/NO2/NO3)으로 분리.
function splitPhone(rawPhone) {
  const digits = String(rawPhone || "").replace(/\D/g, "");
  if (!digits) {
    return { n1: "", n2: "", n3: "" };
  }

  // 010-XXXX-XXXX(11) / 02-XXX(X)-XXXX(9~10) / 0XX-XXX(X)-XXXX 처리
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

  // 형식 불명 — 앞 3자리 / 나머지 분할 (best effort)
  return { n1: digits.slice(0, 3), n2: digits.slice(3, digits.length - 4), n3: digits.slice(-4) };
}

// KST(UTC+9) 기준 오늘 YYYYMMDD (서버리스는 UTC로 동작하므로 보정).
function kstYmd(date = new Date()) {
  const kst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10).replace(/-/g, "");
}

// 'YYYY-MM-DD' (DATE 컬럼) → 'YYYYMMDD'
function dateToYmd(value) {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }
  const digits = text.replace(/[^0-9]/g, "");
  return digits.length >= 8 ? digits.slice(0, 8) : "";
}

// 배송 품목(ARRAY) 구성 — 주문 상품 목록(order_items) 기준.
function buildGoodsArray(order) {
  const items = Array.isArray(order.order_items) ? order.order_items : [];
  if (items.length > 0) {
    return items.map((item, index) => ({
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

// 예약접수(RegBook) 바디 구성. 발송인(SENDR)=수북 입고센터, 수취인(RCVR)=구매자.
function buildRegBookPayload(order, { token, invcNo, cfg }) {
  const warehouse = splitPhone(cfg.warehousePhone);
  const receiver = splitPhone(order.shipping_recipient_phone);

  return {
    CUST_ID: cfg.custId,
    TOKEN_NUM: token,
    RCPT_YMD: kstYmd(),
    CUST_USE_NO: order.order_number, // 고객사용번호(주문번호/멱등 키)
    RCPT_DV: cfg.rcptDv,
    WORK_DV_CD: cfg.workDvCd,
    REQ_DV_CD: cfg.reqDvCd,
    MPCK_KEY: order.order_number,
    CAL_DV_CD: cfg.calDvCd,
    FRT_DV_CD: cfg.frtDvCd,
    CNTR_ITEM_CD: cfg.cntrItemCd,
    BOX_TYPE_CD: cfg.boxTypeCd,
    BOX_QTY: "1", // 배송은 주문당 1박스
    FRT: "0",
    CUST_MGMT_DLCM_CD: cfg.custId,

    // 발송인 = 수북 입고센터
    SENDR_NM: cfg.warehouseName,
    SENDR_TEL_NO1: warehouse.n1,
    SENDR_TEL_NO2: warehouse.n2,
    SENDR_TEL_NO3: warehouse.n3,
    SENDR_CELL_NO1: warehouse.n1,
    SENDR_CELL_NO2: warehouse.n2,
    SENDR_CELL_NO3: warehouse.n3,
    SENDR_ZIP_NO: cfg.warehousePostalCode,
    SENDR_ADDR: cfg.warehouseAddressLine1,
    SENDR_DETAIL_ADDR: cfg.warehouseAddressLine2,

    // 수취인 = 구매자
    RCVR_NM: order.shipping_recipient_name || "",
    RCVR_TEL_NO1: receiver.n1,
    RCVR_TEL_NO2: receiver.n2,
    RCVR_TEL_NO3: receiver.n3,
    RCVR_CELL_NO1: receiver.n1,
    RCVR_CELL_NO2: receiver.n2,
    RCVR_CELL_NO3: receiver.n3,
    RCVR_ZIP_NO: order.shipping_postal_code || "",
    RCVR_ADDR: order.shipping_address_line1 || "",
    RCVR_DETAIL_ADDR: order.shipping_address_line2 || "",

    // 주문자 = 수북 (발송 주체)
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

    INVC_NO: invcNo, // 채번에서 받은 운송장번호
    COLCT_EXPCT_YMD: kstYmd(), // 발송(집화) 예정일 = 오늘
    PRT_ST: cfg.prtSt,
    ARTICLE_AMT: "0",
    REMARK_1: String(order.shipping_memo || "").slice(0, 100),
    COD_YN: cfg.codYn,
    DLV_DV: cfg.dlvDv,
    ARRAY: buildGoodsArray(order),
  };
}

function makeMockTrackingNumber(order) {
  const nowDigits = kstYmd().slice(2) + String(Date.now()).slice(-4);
  const idDigits = String(order.id || 0).padStart(6, "0").slice(-6);
  return `${nowDigits}${idDigits}`.slice(-12).padStart(12, "0");
}

async function registerCjDelivery(order, { token, cfg }) {
  if (isMockMode()) {
    const trackingNumber = makeMockTrackingNumber(order);
    return {
      trackingNumber,
      cjRequestId: `MOCK-${order.order_number}`,
      addr: {
        clsfCd: "2T01", subClsfCd: "1h", clsfAddr: "샘플주소약칭",
        clldlvBranNm: "서울강남서", clldlvEmpNickNm: "H03-6구역", rspsDiv: "01", p2pCd: null,
      },
      rawResponse: { mock: true, RESULT_CD: "S", trackingNumber },
    };
  }

  // 1) 주소정제 → 라벨 라우팅 데이터(분류코드/주소약칭/배송점소).
  // 자체출력 운송장은 분류코드 바코드가 필수라, 주소정제 실패(미존재 주소 등) 시
  // 채번 전에 접수를 차단한다. (CJ 개발환경 검증에서 미존재 주소 2건이 걸러진 건 —
  // 운영 주소는 카카오 우편번호 검색 기반이지만 이중 안전장치. 2026-07-09)
  const addr = await reqAddrRefine(cfg, token, buildFullAddress(order));
  if (!addr?.clsfCd) {
    const error = new Error(
      "CJ 주소정제에 실패했습니다. 배송지 주소가 실제 존재하는 주소인지 확인해 주세요. (분류코드 없이는 운송장 출력 불가)",
    );
    error.code = "CJ_ADDR_REFINE_FAILED";
    throw error;
  }

  // 2) 채번 → 운송장번호 확보
  const invcNo = await reqInvcNo(cfg, token);

  // 3) 예약접수 (헤더 키 = 토큰)
  const payload = buildRegBookPayload(order, { token, invcNo, cfg });
  const body = await postCj(cfg, cfg.regBookEndpoint, payload, token);

  if (!isCjSuccess(body)) {
    throw makeCjBusinessError(body, "CJ_REGBOOK_FAILED");
  }

  // RegBook 성공 응답은 INVC_NO를 돌려주지 않으므로 우리가 채번한 번호가 곧 운송장.
  return {
    trackingNumber: invcNo,
    cjRequestId: invcNo,
    addr,
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

// 배송 송장 발급 가능 상태: 상품 준비 중(preparing) 또는 폐지 전 레거시 paid.
function canRegisterDelivery(order) {
  return ["preparing", "paid"].includes(order.status);
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

function makeFailedResult(orderId, error) {
  return {
    orderId,
    success: false,
    status: "failed",
    error: getErrorDetail(error) || "CJ 배송 접수에 실패했습니다.",
    code: error?.code || "CJ_DELIVERY_FAILED",
  };
}

// 발송인(수북 입고센터) 라벨 데이터 — 등록/재출력 공통.
function buildSenderForLabel(cfg) {
  return {
    name: cfg.warehouseName,
    phone: cfg.warehousePhone,
    zip: cfg.warehousePostalCode,
    addr1: cfg.warehouseAddressLine1,
    addr2: cfg.warehouseAddressLine2,
  };
}

async function processDeliveryRegistration({ supabase, orderId, force, reprint, token, cfg }) {
  const order = await getOrder(supabase, orderId);
  if (!order) {
    return {
      orderId,
      success: false,
      status: "failed",
      error: "주문을 찾을 수 없습니다.",
      code: "ORDER_NOT_FOUND",
    };
  }

  // ── 재출력: 이미 발급된 운송장 라벨 재조회. 채번·예약접수 없음(중복 접수 방지). ──
  if (reprint) {
    if (!order.tracking_number) {
      return {
        orderId,
        orderNumber: order.order_number,
        success: false,
        status: "failed",
        error: "운송장번호가 없어 재출력할 수 없습니다. 먼저 'CJ 송장 출력'으로 발급해 주세요.",
        code: "NO_TRACKING_NUMBER",
      };
    }
    // 라벨 라우팅 데이터(분류코드/주소약칭/배달점소)는 저장돼 있지 않아 주소정제로 재조회.
    // 실패해도(주소정제 불가) 운송장번호·주소 기반으로 라벨은 뜬다 → non-fatal.
    let addr = null;
    if (isMockMode()) {
      addr = {
        clsfCd: "2T01", subClsfCd: "1h", clsfAddr: "샘플주소약칭",
        clldlvBranNm: "서울강남서", clldlvEmpNickNm: "H03-6구역", rspsDiv: "01", p2pCd: null,
      };
    } else {
      try {
        addr = await reqAddrRefine(cfg, token, buildFullAddress(order));
      } catch {
        addr = null;
      }
    }
    return {
      orderId,
      orderNumber: order.order_number,
      success: true,
      status: "reprint",
      trackingNumber: order.tracking_number,
      addr,
      sender: buildSenderForLabel(cfg),
      order,
    };
  }

  // 이미 운송장이 있으면 재발급 방지 (force=true로 강제 재발급 가능)
  if (order.tracking_number && !force) {
    return {
      orderId,
      orderNumber: order.order_number,
      success: true,
      status: "skipped",
      trackingNumber: order.tracking_number,
      order,
    };
  }

  if (!canRegisterDelivery(order)) {
    return {
      orderId,
      orderNumber: order.order_number,
      success: false,
      status: "failed",
      error: `현재 상태에서는 송장 발급이 불가능합니다. (${order.status}) — '상품 준비 중' 주문만 가능합니다.`,
      code: "INVALID_ORDER_STATUS",
    };
  }

  try {
    const cjResult = await registerCjDelivery(order, { token, cfg });
    // 운송장번호 기록 + '배송중' 전환. (auto_confirm_at은 실제 배송완료 시점에 설정)
    const { error: updateError } = await supabase
      .from("orders")
      .update({
        status: "shipping",
        tracking_number: cjResult.trackingNumber,
        tracking_carrier: CJ_CARRIER_NAME,
        updated_at: new Date().toISOString(),
      })
      .eq("id", order.id);

    if (updateError) {
      throw updateError;
    }

    const updatedOrder = await getOrder(supabase, order.id);

    return {
      orderId,
      orderNumber: order.order_number,
      success: true,
      status: "registered",
      trackingNumber: cjResult.trackingNumber,
      cjRequestId: cjResult.cjRequestId,
      // 라벨 렌더용 데이터 — 라우팅(주소정제) + 발송인(수북). 수취인은 order에 있음.
      addr: cjResult.addr,
      sender: buildSenderForLabel(cfg),
      order: updatedOrder,
    };
  } catch (error) {
    return {
      orderId,
      orderNumber: order.order_number,
      ...makeFailedResult(orderId, error),
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

    const orderIds = normalizeIds(body.orderIds ?? body.orderId);
    if (orderIds.length === 0) {
      return res.status(400).json(
        makeErrorResponse({
          error: "orderIds is required.",
          code: "MISSING_ORDER_IDS",
        }),
      );
    }

    if (orderIds.length > MAX_BULK_DELIVERY_COUNT) {
      return res.status(400).json(
        makeErrorResponse({
          error: `한 번에 최대 ${MAX_BULK_DELIVERY_COUNT}건까지 처리할 수 있습니다.`,
          code: "TOO_MANY_ORDERS",
        }),
      );
    }

    // 1Day 토큰은 한 번만 발급해 배치 전체에서 재사용한다.
    const cfg = getCjConfig();
    let token = null;
    let tokenError = null;
    try {
      token = await getOneDayToken(cfg);
    } catch (error) {
      tokenError = error;
    }

    const results = [];
    for (const orderId of orderIds) {
      if (tokenError) {
        results.push(makeFailedResult(orderId, tokenError));
        continue;
      }
      results.push(
        await processDeliveryRegistration({
          supabase,
          orderId,
          force: Boolean(body.force),
          reprint: Boolean(body.reprint),
          token,
          cfg,
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
          : error?.code || error?.message || "CJ_DELIVERY_HANDLER_FAILED";

    console.error("[cj-delivery] handler failure", {
      statusCode,
      code,
      message: error?.message || "",
    });

    return res.status(statusCode).json(
      makeErrorResponse({
        error: statusCode === 403 ? "Admin access required." : "CJ delivery request failed.",
        code,
        detail: getErrorDetail(error),
      }),
    );
  }
}
