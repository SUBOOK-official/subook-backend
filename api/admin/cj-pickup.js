import { createClient } from "@supabase/supabase-js";

// ──────────────────────────────────────────────────────────────────────────
// CJ대한통운 Open API (택배 표준 API) — 수거(집화) 예약 접수
//
// 흐름: ReqOneDayToken(1Day 토큰) → ReqInvcNo(채번=운송장번호) → RegBook(예약접수)
//   RegBook이 ORA-00001(중복 접수)로 거부되면: CnclBook(유령 예약 취소, 오늘~D-2) →
//   재채번 → 재접수 (자동 복구). 접미사 우회는 이중 기사출동 위험으로 수거에는 없음.
// 인증: 헤더 CJ-Gateway-APIKey + 바디 DATA.TOKEN_NUM + DATA.CUST_ID(고객사코드)
// 환경: 테스트 https://dxapi-dev.cjlogistics.com:5054 / 운영 https://dxapi.cjlogistics.com:5052
// 규격: 개발자포털 자료실 "CJLAPI-택배 표준 API Developer Guide" (V3.9.4) 기준
//
// 수북 수거 모델 = 셀러(SENDR, 발송인) → 수북 입고센터(RCVR, 수취인) 집화.
// 응답 래퍼: { "RESULT_CD":"S"|"S200"(성공) | "E"|"E4xx"(실패), "RESULT_DETAIL":..., "DATA":{...} }
// ──────────────────────────────────────────────────────────────────────────

const CJ_REQUEST_TIMEOUT_MS = Number(process.env.CJ_REQUEST_TIMEOUT_MS) || 12_000;
// CJ 운영 서버 콜드 워밍업에서 첫 연결이 자주 끊겨(fetch failed) 여러 번 필요 → 기본 5회.
const CJ_RETRY_COUNT = Number(process.env.CJ_RETRY_COUNT) || 5;
const MAX_BULK_PICKUP_COUNT = 30;
const CJ_CARRIER_NAME = "CJ대한통운";

const DEFAULT_TOKEN_ENDPOINT = "/ReqOneDayToken";
const DEFAULT_INVCNO_ENDPOINT = "/ReqInvcNo";
const DEFAULT_REGBOOK_ENDPOINT = "/RegBook";
const DEFAULT_CNCLBOOK_ENDPOINT = "/CnclBook";

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
  desired_pickup_date,
  box_count,
  expected_book_count,
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
    cnclBookEndpoint: process.env.CJ_CNCLBOOK_ENDPOINT || DEFAULT_CNCLBOOK_ENDPOINT,

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
    // CJ 규격서(V3.9.4) 기준 기본값. 필요 시 env로 조정한다.
    //   RCPT_DV 접수구분(01 일반 / 02 반품 — 수거는 02, 규격서 p.600행 확정),
    //   FRT_DV_CD 운임구분(01 선불 / 02 착불 / 03 신용 — 계약 후불정산),
    //   CAL_DV_CD 정산구분, CNTR_ITEM_CD 품목, BOX_TYPE_CD 박스규격,
    //   PRT_ST 출력상태, COD_YN 착불여부, DLV_DV 택배구분(01 고정), WORK_DV_CD 작업구분.
    rcptDv: process.env.CJ_RCPT_DV || "02",
    workDvCd: process.env.CJ_WORK_DV_CD || "01",
    reqDvCd: process.env.CJ_REQ_DV_CD || "01",
    calDvCd: process.env.CJ_CAL_DV_CD || "1",
    frtDvCd: process.env.CJ_FRT_DV_CD || "03",
    cntrItemCd: process.env.CJ_CNTR_ITEM_CD || "01",
    // BOX_TYPE_CD: 01=극소(3,000원)·02=소(3,500원)·03=중·04=대1·05=이형.
    // 중고 교재는 극소(80cm/2kg 이하) 기본. (과거 '02=소'로 잘못 접수돼 500원 과청구 → 01로 수정)
    boxTypeCd: process.env.CJ_BOX_TYPE_CD || "01",
    // 규격서: "반품(RCPT_DV='02') 진행 시 PRT_ST='01'(미출력) 기재" — 기사가 운송장
    // 출력·부착하는 회수 모델. (선출력 '02'는 배송(일반 접수)용 — cj-delivery 참조.)
    // env 이름도 CJ_PICKUP_PRT_ST로 분리 — cj-delivery의 CJ_PRT_ST와 상호 간섭 방지.
    prtSt: process.env.CJ_PICKUP_PRT_ST || "01",
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

// 수거 품목(ARRAY) 구성. 신규 정책상 pickup_items가 비어있을 수 있어 요약 1줄로 대체.
function buildGoodsArray(pickupRequest) {
  const items = Array.isArray(pickupRequest.pickup_items) ? pickupRequest.pickup_items : [];
  if (items.length > 0) {
    return items.map((item, index) => ({
      MPCK_SEQ: String(index + 1),
      GDS_CD: String(item.id ?? index + 1),
      GDS_NM: String(item.title || "중고 교재").slice(0, 100),
      GDS_QTY: "1",
      UNIT_CD: "EA",
      UNIT_NM: "권",
      GDS_AMT: String(item.original_price ?? 0),
    }));
  }

  const qty = Number(pickupRequest.expected_book_count) || Number(pickupRequest.item_count) || 1;
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

// 예약접수(RegBook) 바디 구성. 발송인(SENDR)=셀러, 수취인(RCVR)=수북 입고센터.
function buildRegBookPayload(pickupRequest, { token, invcNo, cfg }) {
  const sender = splitPhone(pickupRequest.pickup_recipient_phone);
  const warehouse = splitPhone(cfg.warehousePhone);
  const boxQty = Math.max(1, Number(pickupRequest.box_count) || 1);
  const colctYmd = dateToYmd(pickupRequest.desired_pickup_date) || kstYmd();

  return {
    CUST_ID: cfg.custId,
    TOKEN_NUM: token,
    RCPT_YMD: kstYmd(),
    CUST_USE_NO: pickupRequest.request_number, // 고객사용번호(주문/멱등 키)
    RCPT_DV: cfg.rcptDv,
    WORK_DV_CD: cfg.workDvCd,
    REQ_DV_CD: cfg.reqDvCd,
    MPCK_KEY: pickupRequest.request_number,
    CAL_DV_CD: cfg.calDvCd,
    FRT_DV_CD: cfg.frtDvCd,
    CNTR_ITEM_CD: cfg.cntrItemCd,
    BOX_TYPE_CD: cfg.boxTypeCd,
    BOX_QTY: String(boxQty),
    FRT: "0",
    CUST_MGMT_DLCM_CD: cfg.custId,

    // 발송인 = 셀러 (집화 대상)
    SENDR_NM: pickupRequest.pickup_recipient_name || "",
    SENDR_TEL_NO1: sender.n1,
    SENDR_TEL_NO2: sender.n2,
    SENDR_TEL_NO3: sender.n3,
    SENDR_CELL_NO1: sender.n1,
    SENDR_CELL_NO2: sender.n2,
    SENDR_CELL_NO3: sender.n3,
    SENDR_ZIP_NO: pickupRequest.pickup_postal_code || "",
    SENDR_ADDR: pickupRequest.pickup_address_line1 || "",
    SENDR_DETAIL_ADDR: pickupRequest.pickup_address_line2 || "",

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

    // 주문자 = 셀러
    ORDRR_NM: pickupRequest.pickup_recipient_name || "",
    ORDRR_TEL_NO1: sender.n1,
    ORDRR_TEL_NO2: sender.n2,
    ORDRR_TEL_NO3: sender.n3,
    ORDRR_CELL_NO1: sender.n1,
    ORDRR_CELL_NO2: sender.n2,
    ORDRR_CELL_NO3: sender.n3,
    ORDRR_ZIP_NO: pickupRequest.pickup_postal_code || "",
    ORDRR_ADDR: pickupRequest.pickup_address_line1 || "",
    ORDRR_DETAIL_ADDR: pickupRequest.pickup_address_line2 || "",

    INVC_NO: invcNo, // 채번에서 받은 운송장번호
    COLCT_EXPCT_YMD: colctYmd, // 집화(수거) 예정일
    PRT_ST: cfg.prtSt,
    ARTICLE_AMT: "0",
    REMARK_1: String(pickupRequest.pickup_memo || "").slice(0, 100),
    COD_YN: cfg.codYn,
    DLV_DV: cfg.dlvDv,
    ARRAY: buildGoodsArray(pickupRequest),
  };
}

// CJ Oracle unique 제약 위반(= 같은 접수 키로 이미 예약이 존재) 감지.
// 접수 PK = 고객ID+접수일자+CUST_USE_NO이고 우리는 CUST_USE_NO/MPCK_KEY에 요청번호를 넣는다.
function isCjDuplicateBooking(body) {
  return /ORA-00001|unique constraint/i.test(getCjMessage(body));
}

// 예약취소(CnclBook) 바디 — 접수 바디와 동일 구조에 REQ_DV_CD=02(취소), 대상 접수일자 지정.
// 유령 예약의 운송장번호는 알 수 없으므로 INVC_NO는 생략(PK 아님). RCPT_DV=02(수거)는 그대로 매칭.
function buildCancelPayload(pickupRequest, { token, cfg, rcptYmd }) {
  const payload = {
    ...buildRegBookPayload(pickupRequest, { token, invcNo: "", cfg }),
    RCPT_YMD: rcptYmd,
    REQ_DV_CD: "02",
  };
  delete payload.INVC_NO;
  return payload;
}

// 유령 예약(응답 유실로 우리 DB에 기록되지 못한 CJ 접수) 취소.
// 접수일자를 모르므로 오늘~D-2를 순차 시도한다. 대상 없는 날짜는 CJ가 E로 응답 — 무해.
// 실패해도 던지지 않고 결과만 수집한다(이후 재접수 시도가 최종 판정).
async function cancelStrayBookings(pickupRequest, { token, cfg }) {
  const results = [];
  for (let daysAgo = 0; daysAgo <= 2; daysAgo += 1) {
    const rcptYmd = kstYmd(new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000));
    try {
      const body = await postCj(
        cfg,
        cfg.cnclBookEndpoint,
        buildCancelPayload(pickupRequest, { token, cfg, rcptYmd }),
        token,
      );
      results.push({ rcptYmd, ok: isCjSuccess(body), detail: getCjMessage(body).slice(0, 200) });
    } catch (error) {
      results.push({ rcptYmd, ok: false, detail: String(error?.message || "").slice(0, 200) });
    }
  }
  return results;
}

function makeMockTrackingNumber(pickupRequest) {
  const nowDigits = kstYmd().slice(2) + String(Date.now()).slice(-4);
  const idDigits = String(pickupRequest.id || 0).padStart(6, "0").slice(-6);
  return `${nowDigits}${idDigits}`.slice(-12).padStart(12, "0");
}

async function registerCjPickup(pickupRequest, { token, cfg }) {
  if (isMockMode()) {
    const trackingNumber = makeMockTrackingNumber(pickupRequest);
    return {
      trackingNumber,
      cjRequestId: `MOCK-${pickupRequest.request_number}`,
      rawResponse: { mock: true, RESULT_CD: "S", trackingNumber },
    };
  }

  // 1) 채번 → 운송장번호 확보
  let invcNo = await reqInvcNo(cfg, token);

  // 2) 예약접수 (헤더 키 = 토큰)
  let body = await postCj(cfg, cfg.regBookEndpoint, buildRegBookPayload(pickupRequest, { token, invcNo, cfg }), token);
  let healed = null;

  // ── ORA-00001(중복 접수) 자동 복구 ─────────────────────────────────────
  // 과거 시도가 CJ에는 접수됐는데 응답이 유실되면(타임아웃/연결 끊김) 우리 DB에 운송장이
  // 없는 채로 CJ에 유령 예약이 남아, 같은 요청번호 재접수가 전부 중복 거부된다.
  // 유령 예약 취소(CnclBook) 후 새 운송장번호로 1회 재접수.
  // ⚠ 배송(cj-delivery)과 달리 접미사 우회 최후수단은 두지 않는다 — 수거는 접수만으로
  //   기사 출동이 잡히므로, 취소 불가(이미 스캔 등) 상태에서 우회 접수하면 이중 출동이 된다.
  if (!isCjSuccess(body) && isCjDuplicateBooking(body)) {
    console.warn("[cj-pickup] duplicate booking — auto-heal start", {
      requestNumber: pickupRequest.request_number,
      detail: getCjMessage(body).slice(0, 200),
    });
    const cancelResults = await cancelStrayBookings(pickupRequest, { token, cfg });
    console.warn("[cj-pickup] stray cancel results", {
      requestNumber: pickupRequest.request_number,
      cancelResults,
    });

    // 취소된 유령 예약이 물고 있던 번호와 분리되도록 항상 새로 채번한다.
    invcNo = await reqInvcNo(cfg, token);
    body = await postCj(cfg, cfg.regBookEndpoint, buildRegBookPayload(pickupRequest, { token, invcNo, cfg }), token);
    healed = "cancel-reregister";
  }

  if (!isCjSuccess(body)) {
    const error = makeCjBusinessError(body, "CJ_REGBOOK_FAILED");
    if (healed && isCjDuplicateBooking(body)) {
      error.message = `CJ에 같은 요청번호의 수거 예약이 남아 있는데 취소가 불가한 상태입니다 (${getCjMessage(body)}). 기사 배정/스캔이 이미 진행됐을 수 있으니 이중 접수하지 말고, CJ 추적 조회 또는 지점 문의로 기존 접수 상태를 확인해 주세요.`;
    }
    throw error;
  }

  // 성공 즉시 운송장번호를 로그로 남긴다 — 응답 유실·DB 기록 실패 시 복구 근거.
  console.log("[cj-pickup] regbook ok", {
    requestNumber: pickupRequest.request_number,
    invcNo,
    healed,
  });

  // RegBook 성공 응답은 INVC_NO를 돌려주지 않으므로 우리가 채번한 번호가 곧 운송장.
  return {
    trackingNumber: invcNo,
    cjRequestId: invcNo,
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

function makeFailedResult(pickupRequestId, error) {
  return {
    pickupRequestId,
    success: false,
    status: "failed",
    error: getErrorDetail(error) || "CJ 수거 접수에 실패했습니다.",
    code: error?.code || "CJ_PICKUP_FAILED",
  };
}

async function processPickupRegistration({ supabase, pickupRequestId, force, token, cfg }) {
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
    const cjResult = await registerCjPickup(pickupRequest, { token, cfg });
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
      // 자동 복구(유령 예약 취소 후 재접수)로 발급된 경우 표시 — null이면 정상 1회 접수.
      healed: cjResult.healed || null,
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
      ...makeFailedResult(pickupRequestId, error),
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
    for (const pickupRequestId of pickupRequestIds) {
      if (tokenError) {
        results.push(makeFailedResult(pickupRequestId, tokenError));
        continue;
      }
      results.push(
        await processPickupRegistration({
          supabase,
          pickupRequestId,
          force: Boolean(body.force),
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
