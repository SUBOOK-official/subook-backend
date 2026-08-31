import { createClient } from "@supabase/supabase-js";

// ──────────────────────────────────────────────────────────────────────────
// CJ대한통운 Open API (택배 표준 API) — 수거(집화) 예약 접수 + 예약 취소
//
// 접수 흐름: ReqOneDayToken(1Day 토큰) → ReqInvcNo(채번=운송장번호) → RegBook(예약접수)
//   RegBook이 ORA-00001(중복 접수)로 거부되면: CnclBook(유령 예약 취소, 오늘~D-2) →
//   재채번 → 재접수 (자동 복구). 접미사 우회는 이중 기사출동 위험으로 수거에는 없음.
// 취소 흐름(action=cancel): 접수된 박스별 CnclBook → 전부 성공해야 DB 상태도 cancelled.
//   CJ 취소 불가 사유(기사 스캔·운송장 출력 등)는 결과에 원문으로 실어 UI에 노출한다.
//   (과거 admin 취소가 DB만 바꿔 CJ 예약이 살아남던 문제의 수리 — 2026-08-08 조영훈 건)
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
// 요청당 박스 상한 — CJ 접수는 박스당 1건씩 나가므로 폭주 방어. 초과 시 요청 분할 안내.
const MAX_BOXES_PER_REQUEST = Number(process.env.CJ_MAX_BOXES_PER_REQUEST) || 5;
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
  box_waybills,
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

// 박스별 CJ 고객사용번호. CJ 접수 PK가 (고객ID+접수일자+CUST_USE_NO)라 박스마다 달라야 한다.
// 1번 박스는 기존 접수분과의 호환을 위해 요청번호 그대로, 2번째부터 "-B<seq>" 접미사.
// (요청번호 자체에 접미사를 붙이면 우리 DB의 번호 생성기가 깨지므로 CJ 전송용으로만 쓴다.)
function boxCustUseNo(requestNumber, boxSeq) {
  return boxSeq === 1 ? requestNumber : `${requestNumber}-B${boxSeq}`;
}

// 예약접수(RegBook) 바디 구성. 발송인(SENDR)=셀러, 수취인(RCVR)=수북 입고센터.
// ⚠ 멀티박스: CJ 운송장은 박스(개별 화물)당 1장 필요 — 박스마다 이 payload로 접수 1건씩
//   나간다. BOX_QTY는 항상 1 (과거엔 box_count를 넣고 접수는 1건만 해서 송장이 모자랐음).
function buildRegBookPayload(pickupRequest, { token, invcNo, cfg, boxSeq = 1, totalBoxes = 1 }) {
  const sender = splitPhone(pickupRequest.pickup_recipient_phone);
  const warehouse = splitPhone(cfg.warehousePhone);
  const custUseNo = boxCustUseNo(pickupRequest.request_number, boxSeq);
  const colctYmd = dateToYmd(pickupRequest.desired_pickup_date) || kstYmd();
  // 기사님이 현장에서 몇 박스째인지 알 수 있도록 REMARK 앞에 표기
  const boxPrefix = totalBoxes > 1 ? `[박스 ${boxSeq}/${totalBoxes}] ` : "";

  return {
    CUST_ID: cfg.custId,
    TOKEN_NUM: token,
    RCPT_YMD: kstYmd(),
    CUST_USE_NO: custUseNo, // 고객사용번호(주문/멱등 키, 박스별로 상이)
    RCPT_DV: cfg.rcptDv,
    WORK_DV_CD: cfg.workDvCd,
    REQ_DV_CD: cfg.reqDvCd,
    MPCK_KEY: custUseNo,
    CAL_DV_CD: cfg.calDvCd,
    FRT_DV_CD: cfg.frtDvCd,
    CNTR_ITEM_CD: cfg.cntrItemCd,
    BOX_TYPE_CD: cfg.boxTypeCd,
    BOX_QTY: "1",
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
    // 상세주소 미입력 대응 — CJ Oracle은 빈 문자열을 NULL로 취급해 ORA-01400으로 접수를 거부한다.
    SENDR_DETAIL_ADDR: String(pickupRequest.pickup_address_line2 || "").trim() || "-",

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
    ORDRR_DETAIL_ADDR: String(pickupRequest.pickup_address_line2 || "").trim() || "-",

    INVC_NO: invcNo, // 채번에서 받은 운송장번호
    COLCT_EXPCT_YMD: colctYmd, // 집화(수거) 예정일
    PRT_ST: cfg.prtSt,
    ARTICLE_AMT: "0",
    REMARK_1: (boxPrefix + String(pickupRequest.pickup_memo || "")).slice(0, 100),
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
// 박스별 CUST_USE_NO가 접수 키이므로 취소도 같은 boxSeq로 맞춰야 해당 박스 예약만 취소된다.
// custUseNo를 넘기면 boxSeq 유도값 대신 그 값으로 매칭한다(box_waybills에 기록된 실제 접수 키 우선
// — 부분수거 복구 백필처럼 기록과 유도값이 다를 수 있어, 실제 CJ에 나간 번호가 진실이다).
function buildCancelPayload(pickupRequest, { token, cfg, rcptYmd, boxSeq = 1, totalBoxes = 1, custUseNo = "" }) {
  const payload = {
    ...buildRegBookPayload(pickupRequest, { token, invcNo: "", cfg, boxSeq, totalBoxes }),
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

// 유령 예약(응답 유실로 우리 DB에 기록되지 못한 CJ 접수) 취소.
// 접수일자를 모르므로 오늘~D-2를 순차 시도한다. 대상 없는 날짜는 CJ가 E로 응답 — 무해.
// 실패해도 던지지 않고 결과만 수집한다(이후 재접수 시도가 최종 판정).
async function cancelStrayBookings(pickupRequest, { token, cfg, boxSeq = 1, totalBoxes = 1 }) {
  const results = [];
  for (let daysAgo = 0; daysAgo <= 2; daysAgo += 1) {
    const rcptYmd = kstYmd(new Date(Date.now() - daysAgo * 24 * 60 * 60 * 1000));
    try {
      const body = await postCj(
        cfg,
        cfg.cnclBookEndpoint,
        buildCancelPayload(pickupRequest, { token, cfg, rcptYmd, boxSeq, totalBoxes }),
        token,
      );
      results.push({ rcptYmd, ok: isCjSuccess(body), detail: getCjMessage(body).slice(0, 200) });
    } catch (error) {
      results.push({ rcptYmd, ok: false, detail: String(error?.message || "").slice(0, 200) });
    }
  }
  return results;
}

function makeMockTrackingNumber(pickupRequest, boxSeq = 1) {
  const nowDigits = kstYmd().slice(2) + String(Date.now()).slice(-4);
  const idDigits = String((pickupRequest.id || 0) * 10 + boxSeq).padStart(6, "0").slice(-6);
  return `${nowDigits}${idDigits}`.slice(-12).padStart(12, "0");
}

// 박스 1개 접수: 채번 → RegBook (+ORA-00001 자동 복구). 멀티박스 요청은 이 함수를
// 박스 수만큼 호출한다 — 운송장은 박스당 1장이라 접수도 박스당 1건이어야 한다.
async function registerCjPickupBox(pickupRequest, { token, cfg, boxSeq, totalBoxes }) {
  const custUseNo = boxCustUseNo(pickupRequest.request_number, boxSeq);

  if (isMockMode()) {
    const trackingNumber = makeMockTrackingNumber(pickupRequest, boxSeq);
    return {
      trackingNumber,
      custUseNo,
      cjRequestId: `MOCK-${custUseNo}`,
      rawResponse: { mock: true, RESULT_CD: "S", trackingNumber },
    };
  }

  // 1) 채번 → 운송장번호 확보
  let invcNo = await reqInvcNo(cfg, token);

  // 2) 예약접수 (헤더 키 = 토큰)
  let body = await postCj(cfg, cfg.regBookEndpoint, buildRegBookPayload(pickupRequest, { token, invcNo, cfg, boxSeq, totalBoxes }), token);
  let healed = null;

  // ── ORA-00001(중복 접수) 자동 복구 ─────────────────────────────────────
  // 과거 시도가 CJ에는 접수됐는데 응답이 유실되면(타임아웃/연결 끊김) 우리 DB에 운송장이
  // 없는 채로 CJ에 유령 예약이 남아, 같은 고객사용번호 재접수가 전부 중복 거부된다.
  // 유령 예약 취소(CnclBook) 후 새 운송장번호로 1회 재접수. 취소도 같은 박스의
  // CUST_USE_NO로 나가므로 다른 박스의 정상 예약은 건드리지 않는다.
  // ⚠ 배송(cj-delivery)과 달리 접미사 우회 최후수단은 두지 않는다 — 수거는 접수만으로
  //   기사 출동이 잡히므로, 취소 불가(이미 스캔 등) 상태에서 우회 접수하면 이중 출동이 된다.
  if (!isCjSuccess(body) && isCjDuplicateBooking(body)) {
    console.warn("[cj-pickup] duplicate booking — auto-heal start", {
      custUseNo,
      detail: getCjMessage(body).slice(0, 200),
    });
    const cancelResults = await cancelStrayBookings(pickupRequest, { token, cfg, boxSeq, totalBoxes });
    console.warn("[cj-pickup] stray cancel results", {
      custUseNo,
      cancelResults,
    });

    // 취소된 유령 예약이 물고 있던 번호와 분리되도록 항상 새로 채번한다.
    invcNo = await reqInvcNo(cfg, token);
    body = await postCj(cfg, cfg.regBookEndpoint, buildRegBookPayload(pickupRequest, { token, invcNo, cfg, boxSeq, totalBoxes }), token);
    healed = "cancel-reregister";
  }

  if (!isCjSuccess(body)) {
    const error = makeCjBusinessError(body, "CJ_REGBOOK_FAILED");
    if (healed && isCjDuplicateBooking(body)) {
      error.message = `CJ에 같은 고객사용번호(${custUseNo})의 수거 예약이 남아 있는데 취소가 불가한 상태입니다 (${getCjMessage(body)}). 기사 배정/스캔이 이미 진행됐을 수 있으니 이중 접수하지 말고, CJ 추적 조회 또는 지점 문의로 기존 접수 상태를 확인해 주세요.`;
    }
    throw error;
  }

  // 성공 즉시 운송장번호를 로그로 남긴다 — 응답 유실·DB 기록 실패 시 복구 근거.
  console.log("[cj-pickup] regbook ok", {
    custUseNo,
    invcNo,
    healed,
  });

  // RegBook 성공 응답은 INVC_NO를 돌려주지 않으므로 우리가 채번한 번호가 곧 운송장.
  return {
    trackingNumber: invcNo,
    custUseNo,
    cjRequestId: invcNo,
    healed,
    rawResponse: body,
  };
}

// 박스별 운송장 기록 정규화. 멀티박스 도입 전 접수분(레거시)은 box_waybills가 비어
// 있으므로 tracking_number 존재 시 1번 박스 접수분으로 간주한다.
// 알려진 필드 외의 키(cj-tracking.js가 병합하는 tracking_status 등)는 보존해,
// 미접수 박스 재접수 때 기존 박스의 트래킹 현황이 지워지지 않게 한다.
function normalizeBoxWaybills(pickupRequest) {
  const raw = Array.isArray(pickupRequest.box_waybills) ? pickupRequest.box_waybills : [];
  const entries = raw
    .map((entry) => ({
      ...(entry && typeof entry === "object" ? entry : {}),
      box_seq: Number(entry?.box_seq),
      tracking_number: String(entry?.tracking_number || "").trim(),
      cust_use_no: String(entry?.cust_use_no || "").trim(),
      registered_at: entry?.registered_at ?? null,
    }))
    .filter((entry) => Number.isInteger(entry.box_seq) && entry.box_seq >= 1 && entry.tracking_number);

  if (entries.length === 0 && pickupRequest.tracking_number) {
    entries.push({
      box_seq: 1,
      tracking_number: pickupRequest.tracking_number,
      cust_use_no: pickupRequest.request_number,
      registered_at: pickupRequest.cj_pickup_registered_at || null,
    });
  }

  return entries.sort((a, b) => a.box_seq - b.box_seq);
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

  const totalBoxes = Math.max(1, Number(pickupRequest.box_count) || 1);
  if (totalBoxes > MAX_BOXES_PER_REQUEST) {
    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: false,
      status: "failed",
      error: `박스 ${totalBoxes}개는 요청당 상한(${MAX_BOXES_PER_REQUEST}개)을 초과합니다. 수거 요청을 나눠서 접수해 주세요.`,
      code: "TOO_MANY_BOXES",
    };
  }

  // 이미 접수된 박스는 건너뛰고 미접수 박스만 접수한다(부분 실패 후 재시도 = 멱등).
  // force는 기록 무시 후 전체 재접수 — 기존 예약이 살아있으면 박스별 자동 복구(취소→재접수)로 흡수.
  // CJ 취소된 박스(cancelled_at)는 접수분으로 치지 않는다 — 취소 후 재접수 대상.
  const existingWaybills = force ? [] : normalizeBoxWaybills(pickupRequest);
  const activeWaybills = existingWaybills.filter((entry) => !entry.cancelled_at);
  const existingSeqs = new Set(activeWaybills.map((entry) => entry.box_seq));
  const missingSeqs = [];
  for (let seq = 1; seq <= totalBoxes; seq += 1) {
    if (!existingSeqs.has(seq)) {
      missingSeqs.push(seq);
    }
  }

  if (missingSeqs.length === 0) {
    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: true,
      status: "skipped",
      trackingNumber: pickupRequest.tracking_number,
      registeredBoxes: activeWaybills.length,
      totalBoxes,
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

  let waybills = existingWaybills;
  const registeredResults = [];
  const boxErrors = [];

  for (const boxSeq of missingSeqs) {
    try {
      const cjResult = await registerCjPickupBox(pickupRequest, { token, cfg, boxSeq, totalBoxes });
      const registeredAt = new Date().toISOString();
      const entry = {
        box_seq: boxSeq,
        tracking_number: cjResult.trackingNumber,
        cust_use_no: cjResult.custUseNo,
        registered_at: registeredAt,
      };
      waybills = [...waybills.filter((w) => w.box_seq !== boxSeq), entry].sort((a, b) => a.box_seq - b.box_seq);

      // 박스별 즉시 저장 — 후속 박스 실패나 응답 유실에도 이미 발급된 운송장을 잃지 않는다.
      const update = {
        status: "pickup_scheduled",
        box_waybills: waybills,
      };
      if (boxSeq === 1) {
        // 대표 운송장(기존 단일 컬럼)은 1번 박스 기준 유지 — 트래킹·알림톡·목록 표시 호환.
        update.tracking_number = cjResult.trackingNumber;
        update.tracking_carrier = CJ_CARRIER_NAME;
        update.cj_request_id = cjResult.cjRequestId;
        update.cj_pickup_registered_at = registeredAt;
        update.cj_pickup_response = cjResult.rawResponse;
      }

      const { error: updateError } = await supabase
        .from("pickup_requests")
        .update(update)
        .eq("id", pickupRequest.id);

      if (updateError) {
        // CJ 접수는 성공했는데 DB 기록이 실패한 상태 — 이벤트 로그의 운송장번호가 복구 근거.
        updateError.trackingNumber = cjResult.trackingNumber;
        throw updateError;
      }

      await saveLogisticsEvent(supabase, {
        pickup_request_id: pickupRequest.id,
        event_type: "pickup_register",
        status: "success",
        tracking_number: cjResult.trackingNumber,
        payload: { box_seq: boxSeq, total_boxes: totalBoxes, cust_use_no: cjResult.custUseNo, ...cjResult.rawResponse },
      });

      registeredResults.push({ boxSeq, trackingNumber: cjResult.trackingNumber, healed: cjResult.healed || null });
    } catch (error) {
      await saveLogisticsEvent(supabase, {
        pickup_request_id: pickupRequest.id,
        event_type: "pickup_register",
        status: "failed",
        tracking_number: error?.trackingNumber || pickupRequest.tracking_number,
        error_message: `[박스 ${boxSeq}/${totalBoxes}] ${getErrorDetail(error)}`,
        payload: error?.responseBody || null,
      });
      boxErrors.push({ boxSeq, error, detail: getErrorDetail(error) });
    }
  }

  // 리페치 실패가 접수 결과 자체를 실패로 둔갑시키지 않도록 방어 (운송장은 이미 박스별로 저장됨)
  let updatedPickupRequest = null;
  try {
    updatedPickupRequest = await getPickupRequest(supabase, pickupRequest.id);
  } catch (refetchError) {
    console.error("[cj-pickup] refetch after register failed", {
      requestNumber: pickupRequest.request_number,
      message: refetchError?.message || "",
    });
  }
  const registeredCount = (updatedPickupRequest
    ? normalizeBoxWaybills(updatedPickupRequest)
    : waybills
  ).filter((entry) => !entry.cancelled_at).length;

  if (boxErrors.length > 0) {
    const failedSeqText = boxErrors.map((be) => be.boxSeq).join(", ");
    return {
      pickupRequestId,
      requestNumber: pickupRequest.request_number,
      success: false,
      status: "failed",
      error:
        `박스 ${failedSeqText}번 접수 실패 (${totalBoxes}박스 중 ${registeredCount}건 접수됨 — ` +
        `재시도하면 남은 박스만 다시 접수합니다): ${boxErrors[0].detail || "CJ 수거 접수에 실패했습니다."}`,
      code: boxErrors[0].error?.code || "CJ_PICKUP_FAILED",
      registeredBoxes: registeredCount,
      totalBoxes,
      pickupRequest: updatedPickupRequest,
    };
  }

  return {
    pickupRequestId,
    requestNumber: pickupRequest.request_number,
    success: true,
    status: "registered",
    trackingNumber: updatedPickupRequest?.tracking_number || registeredResults[0]?.trackingNumber,
    cjRequestId: updatedPickupRequest?.cj_request_id || null,
    // 자동 복구(유령 예약 취소 후 재접수)로 발급된 박스가 있으면 표시 — null이면 정상 접수.
    healed: registeredResults.find((r) => r.healed)?.healed || null,
    registeredBoxes: registeredCount,
    totalBoxes,
    pickupRequest: updatedPickupRequest,
  };
}

// ──────────────────────────────────────────────────────────────────────────
// 수거 취소 (action=cancel) — CJ CnclBook + DB 상태 취소를 한 흐름으로.
//
// 원칙: CJ에 접수된(운송장 발급) 요청은 CJ 예약이 전부 취소돼야만 DB도 cancelled로
// 바꾼다. CJ가 거부(기사 스캔·운송장 출력 등)하면 요청을 살려둔 채 거부 사유를
// 그대로 올린다 — 이미 수거가 진행 중일 수 있어 DB만 바꾸면 물건이 오는데 기록은
// 취소인 모순이 생긴다. (DB만 취소하는 강제 경로는 UI에서 기존 RPC로 별도 제공)
// ──────────────────────────────────────────────────────────────────────────

const CANCELLABLE_PICKUP_STATUSES = ["pending", "pickup_scheduled"];

// 이 요청 번호 체계로 접수된 CUST_USE_NO인지 — 요청번호 그대로(box1) 또는 "-B<seq>"(box2+).
// 부분수거 복구 백필처럼 다른 요청 번호로 커버된 박스는 여기서 취소하면 그 요청의
// 살아있는 예약을 죽이므로(조이선 PU-2608-0005 box2 = PU-2608-0006 케이스) 제외한다.
function isOwnBoxCustUseNo(custUseNo, requestNumber) {
  return custUseNo === requestNumber || custUseNo.startsWith(`${requestNumber}-B`);
}

// CnclBook 매칭 키인 접수일자(RCPT_YMD)를 접수 시점 타임스탬프에서 복원 — 반드시 KST 날짜.
// (조영훈 건: UTC 7/28 17:05 = KST 7/29 02:05 → '20260729'. UTC 날짜를 쓰면 매칭 실패)
function resolveBoxRcptYmd(entry, pickupRequest) {
  const source = entry.registered_at || pickupRequest.cj_pickup_registered_at;
  if (!source) {
    return "";
  }
  const date = new Date(source);
  return Number.isNaN(date.getTime()) ? "" : kstYmd(date);
}

// 이 요청에서 CJ 취소를 시도할 박스 목록 + 대상 외 박스 안내.
function listCancellableCjBoxes(pickupRequest) {
  const boxes = [];
  const skippedNotes = [];
  const seen = new Set();

  for (const entry of normalizeBoxWaybills(pickupRequest)) {
    if (entry.cancelled_at) {
      continue; // 이미 CJ 취소 완료 — 재시도 시 건너뜀(멱등)
    }
    const custUseNo = entry.cust_use_no || boxCustUseNo(pickupRequest.request_number, entry.box_seq);
    if (!isOwnBoxCustUseNo(custUseNo, pickupRequest.request_number)) {
      skippedNotes.push(
        `박스 ${entry.box_seq}는 별도 요청(${custUseNo})으로 접수되어 있습니다 — 해당 요청에서 취소해야 합니다.`,
      );
      continue;
    }
    if (seen.has(custUseNo)) {
      continue;
    }
    seen.add(custUseNo);
    boxes.push({ ...entry, cust_use_no: custUseNo });
  }

  return { boxes, skippedNotes };
}

// 박스 1개 CnclBook. 실패는 throw — 호출부가 박스 단위로 수집한다.
async function cancelCjPickupBox(pickupRequest, entry, { getToken, cfg }) {
  const rcptYmd = resolveBoxRcptYmd(entry, pickupRequest);
  if (!rcptYmd) {
    const error = new Error(
      `박스 ${entry.box_seq} (${entry.cust_use_no}): 접수일자를 알 수 없어 CJ 취소를 보낼 수 없습니다 — CJ 지점 문의가 필요합니다.`,
    );
    error.code = "CJ_CANCEL_NO_RCPT_YMD";
    throw error;
  }

  if (isMockMode()) {
    return { rcptYmd, rawResponse: { mock: true, RESULT_CD: "S" } };
  }

  const token = await getToken();
  const body = await postCj(
    cfg,
    cfg.cnclBookEndpoint,
    buildCancelPayload(pickupRequest, {
      token,
      cfg,
      rcptYmd,
      boxSeq: entry.box_seq,
      custUseNo: entry.cust_use_no,
    }),
    token,
  );

  if (!isCjSuccess(body)) {
    // CJ 거부 — RESULT_DETAIL 원문을 그대로 실어 UI에서 판단하게 한다.
    // (이미 스캔/출력이면 수거가 진행 중일 수 있고, '대상 없음'이면 CJ측에 예약이 없는 것)
    const error = new Error(
      `박스 ${entry.box_seq} (${entry.cust_use_no}): ${getCjMessage(body) || "CJ 예약취소가 거부되었습니다."}`,
    );
    error.code = "CJ_CANCEL_REFUSED";
    error.statusCode = 502;
    error.responseBody = body;
    throw error;
  }

  return { rcptYmd, rawResponse: body };
}

// 박스별 CJ 취소 성공을 box_waybills에 즉시 기록(cancelled_at) — 재시도 멱등의 근거.
// 원본 배열을 박스 단위로 병합해 다른 필드(트래킹 현황 등)와 다른 박스 기록을 보존한다.
// 레거시(box_waybills가 빈) 건은 합성 엔트리를 실체화하며 기록한다.
function applyBoxCancelledAt(rawWaybills, entry, cancelledAt) {
  if (rawWaybills.length > 0) {
    return rawWaybills.map((waybill) =>
      Number(waybill?.box_seq) === entry.box_seq ? { ...waybill, cancelled_at: cancelledAt } : waybill,
    );
  }
  return [
    {
      box_seq: entry.box_seq,
      tracking_number: entry.tracking_number,
      cust_use_no: entry.cust_use_no,
      registered_at: entry.registered_at,
      cancelled_at: cancelledAt,
    },
  ];
}

// 이 요청의 살아있는 CJ 예약 박스를 전부 취소하고 box_waybills(cancelled_at)에 기록한다.
// 성공/실패를 박스 단위로 수집만 하고 판정은 호출부에 맡긴다 — 취소 확정(processPickupCancellation)과
// 재접수(processPickupReregistration)가 같은 취소 절차를 공유하되 후속 처리가 다르기 때문.
async function cancelAllCjBoxes({ supabase, pickupRequest, getToken, cfg }) {
  const { boxes, skippedNotes } = listCancellableCjBoxes(pickupRequest);

  let rawWaybills = Array.isArray(pickupRequest.box_waybills) ? pickupRequest.box_waybills : [];
  const boxErrors = [];
  let cancelledBoxes = 0;

  for (const entry of boxes) {
    try {
      const cjResult = await cancelCjPickupBox(pickupRequest, entry, { getToken, cfg });
      const cancelledAt = new Date().toISOString();
      rawWaybills = applyBoxCancelledAt(rawWaybills, entry, cancelledAt);

      // 박스별 즉시 저장 — 후속 박스 실패나 응답 유실에도 이미 취소된 박스를 다시 쏘지 않는다.
      const { error: updateError } = await supabase
        .from("pickup_requests")
        .update({ box_waybills: rawWaybills })
        .eq("id", pickupRequest.id);
      if (updateError) {
        // CJ 취소는 됐는데 기록 실패 — 이벤트 로그가 복구 근거.
        throw updateError;
      }

      await saveLogisticsEvent(supabase, {
        pickup_request_id: pickupRequest.id,
        event_type: "pickup_cancel",
        status: "success",
        tracking_number: entry.tracking_number,
        payload: {
          box_seq: entry.box_seq,
          cust_use_no: entry.cust_use_no,
          rcpt_ymd: cjResult.rcptYmd,
          ...cjResult.rawResponse,
        },
      });
      cancelledBoxes += 1;
    } catch (error) {
      await saveLogisticsEvent(supabase, {
        pickup_request_id: pickupRequest.id,
        event_type: "pickup_cancel",
        status: "failed",
        tracking_number: entry.tracking_number,
        error_message: getErrorDetail(error),
        payload: error?.responseBody || null,
      });
      boxErrors.push({
        boxSeq: entry.box_seq,
        code: error?.code,
        detail: String(error?.message || getErrorDetail(error)),
      });
    }
  }

  return { boxes, skippedNotes, cancelledBoxes, boxErrors };
}

async function processPickupCancellation({ supabase, pickupRequestId, reason, getToken, cfg }) {
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

  const base = {
    pickupRequestId,
    requestNumber: pickupRequest.request_number,
    requestStatus: pickupRequest.status,
  };

  // 이미 취소된 요청도 CJ 예약 정리(cleanup)만은 허용 — CnclBook 미연동 시절/DB만 취소
  // 경로로 남은 살아있는 예약(조영훈 PU-2607-0002)을 걷어내는 자기수리 경로.
  const isCleanupOnly = pickupRequest.status === "cancelled";
  if (!isCleanupOnly && !CANCELLABLE_PICKUP_STATUSES.includes(pickupRequest.status)) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: "INVALID_PICKUP_STATUS",
      error: `이미 수거가 진행/완료된 상태(${pickupRequest.status})라 취소할 수 없습니다.`,
    };
  }

  const { boxes, skippedNotes, cancelledBoxes, boxErrors } = await cancelAllCjBoxes({
    supabase,
    pickupRequest,
    getToken,
    cfg,
  });

  if (boxErrors.length > 0) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: boxErrors[0].code || "CJ_CANCEL_FAILED",
      cancelledBoxes,
      totalCjBoxes: boxes.length,
      skippedNotes,
      error:
        boxErrors.map((boxError) => boxError.detail).join(" / ") +
        (isCleanupOnly
          ? ""
          : " — 수거 요청은 취소되지 않았습니다. 기사 스캔·운송장 출력 후에는 CJ 취소가 불가하며, 이미 수거가 진행 중일 수 있으니 추적 조회나 CJ 지점으로 확인해 주세요."),
    };
  }

  if (isCleanupOnly) {
    return {
      ...base,
      success: true,
      status: cancelledBoxes > 0 ? "cj_cleaned" : "skipped",
      cancelledBoxes,
      totalCjBoxes: boxes.length,
      skippedNotes,
    };
  }

  // CJ측 정리가 끝난 뒤에만 DB 취소 — admin_bulk_cancel_pickup_requests RPC와 동일 의미
  // (pending/pickup_scheduled만, 사유 저장). 동시 상태 변경은 조건 불일치로 0건이 된다.
  const { data: updatedRows, error: cancelError } = await supabase
    .from("pickup_requests")
    .update({
      status: "cancelled",
      cancel_reason: String(reason || "").trim() || null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", pickupRequest.id)
    .in("status", CANCELLABLE_PICKUP_STATUSES)
    .select("id");

  if (cancelError) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: "DB_CANCEL_FAILED",
      cancelledBoxes,
      totalCjBoxes: boxes.length,
      skippedNotes,
      error: `CJ 예약은 취소됐지만 DB 상태 변경에 실패했습니다 (${cancelError.message}) — 다시 시도해 주세요.`,
    };
  }

  if (!updatedRows || updatedRows.length === 0) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: "STATUS_CHANGED_CONCURRENTLY",
      cancelledBoxes,
      totalCjBoxes: boxes.length,
      skippedNotes,
      error:
        "처리 중 상태가 바뀌어 취소를 반영하지 못했습니다. 목록을 새로고침해 현재 상태를 확인해 주세요." +
        (cancelledBoxes > 0 ? " (이 요청의 CJ 예약은 이미 취소되었습니다.)" : ""),
    };
  }

  return {
    ...base,
    success: true,
    status: "cancelled",
    cancelledBoxes,
    totalCjBoxes: boxes.length,
    skippedNotes,
  };
}

// ──────────────────────────────────────────────────────────────────────────
// 수거 재접수 (action=reregister) — 기존 CJ 예약 전량 취소 → 새 조건으로 다시 접수.
//
// 배경: 셀러가 신청과 다르게 포장해 기사가 수거를 거부하는 사고(2박스 신청 → 1박스에
//   몰아담아 20kg 초과, PU-2608-0020 / 2026-08-31)가 생기면 재포장 후 다시 접수해야 한다.
//   그런데 기존 경로에는 재접수 수단이 없었다 — 접수가 끝난 요청은 접수 버튼이 숨겨지고,
//   [수거 취소]를 누르면 status=cancelled로 잠겨 그 요청은 영영 다시 접수할 수 없었다.
//
// ⚠ 안전 규칙: 기존 예약이 하나라도 취소되지 않으면 재접수하지 않는다. 수거는 접수만으로
//   기사 출동이 잡히므로, 살아있는 예약 위에 덧접수하면 기사가 두 번 출동한다.
//   (registerCjPickupBox의 접미사 우회를 수거에서 뺀 것과 같은 이유.)
// ──────────────────────────────────────────────────────────────────────────

const REREGISTERABLE_PICKUP_STATUSES = ["pending", "pickup_scheduled"];

async function processPickupReregistration({
  supabase,
  pickupRequestId,
  boxCount,
  desiredPickupDate,
  skipCancel = false,
  getToken,
  cfg,
}) {
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

  const base = {
    pickupRequestId,
    requestNumber: pickupRequest.request_number,
    requestStatus: pickupRequest.status,
  };

  if (!REREGISTERABLE_PICKUP_STATUSES.includes(pickupRequest.status)) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: "INVALID_PICKUP_STATUS",
      error: `이미 수거가 진행/완료된 상태(${pickupRequest.status})라 재접수할 수 없습니다.`,
    };
  }

  const nextBoxCount =
    Number.isInteger(boxCount) && boxCount >= 1
      ? boxCount
      : Math.max(1, Number(pickupRequest.box_count) || 1);

  if (nextBoxCount > MAX_BOXES_PER_REQUEST) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: "TOO_MANY_BOXES",
      error: `박스 ${nextBoxCount}개는 요청당 상한(${MAX_BOXES_PER_REQUEST}개)을 초과합니다.`,
    };
  }

  // 1) 기존 예약 전량 취소 — 하나라도 실패하면 재접수하지 않는다(이중 출동 방지).
  //    skipCancel은 "CJ에 기존 예약이 이미 없다"를 운영자가 확인한 경우의 탈출구.
  //    CJ 취소 거부 사유는 '기사 스캔 완료'와 '대상 없음'이 모두 같은 E 코드로 오고
  //    규격서에도 구분 코드가 없어(V3.9.4) 자동 판별하지 않는다 — 사유 원문을 사람에게 보이고
  //    명시적으로 한 번 더 누르게 한다. (취소 플로우의 'DB만 취소' 폴백과 같은 방식)
  let cancelledBoxes = 0;
  let skippedNotes = [];

  if (!skipCancel) {
    const cancelResult = await cancelAllCjBoxes({ supabase, pickupRequest, getToken, cfg });
    cancelledBoxes = cancelResult.cancelledBoxes;
    skippedNotes = cancelResult.skippedNotes;

    if (cancelResult.boxErrors.length > 0) {
      return {
        ...base,
        success: false,
        status: "failed",
        code: cancelResult.boxErrors[0].code || "CJ_CANCEL_FAILED",
        cancelledBoxes,
        skippedNotes,
        // 클라이언트가 '취소 없이 재접수' 폴백을 띄울지 판단하는 근거.
        canSkipCancel: true,
        error:
          cancelResult.boxErrors.map((boxError) => boxError.detail).join(" / ") +
          " — 기존 예약이 남아 있어 재접수하지 않았습니다. 살아있는 예약 위에 덧접수하면 기사가 두 번 출동합니다. 추적 조회나 CJ 지점으로 기존 예약 상태를 확인한 뒤 다시 시도해 주세요.",
      };
    }
  }

  // 2) 재접수 조건 반영 (박스 수 · 수거 예정일)
  //    수거 예정일은 COLCT_EXPCT_YMD로 그대로 나가므로, 지난 날짜인 채로 재접수하면 안 된다.
  const update = {};
  if (nextBoxCount !== Number(pickupRequest.box_count)) {
    update.box_count = nextBoxCount;
  }
  if (desiredPickupDate) {
    update.desired_pickup_date = desiredPickupDate;
  }

  if (Object.keys(update).length > 0) {
    update.updated_at = new Date().toISOString();
    const { error: updateError } = await supabase
      .from("pickup_requests")
      .update(update)
      .eq("id", pickupRequest.id);

    if (updateError) {
      return {
        ...base,
        success: false,
        status: "failed",
        code: "DB_UPDATE_FAILED",
        cancelledBoxes,
        skippedNotes,
        error: `기존 CJ 예약은 취소했지만 재접수 조건 저장에 실패했습니다 (${updateError.message}) — 다시 시도해 주세요.`,
      };
    }
  }

  // 3) 새 조건으로 재접수. 취소된 박스(cancelled_at)는 접수분으로 치지 않으므로
  //    processPickupRegistration이 전 박스를 미접수로 보고 새 운송장을 발급한다.
  let token = null;
  try {
    token = await getToken();
  } catch (error) {
    return {
      ...base,
      success: false,
      status: "failed",
      code: "CJ_TOKEN_FAILED",
      cancelledBoxes,
      skippedNotes,
      error: `기존 CJ 예약은 취소됐지만 토큰 발급에 실패해 재접수하지 못했습니다 (${getErrorDetail(error)}) — [CJ 재접수]를 다시 눌러 주세요.`,
    };
  }

  // skipCancel이면 기존 박스에 cancelled_at이 안 찍혀 있어 미접수로 안 보이므로 force로 전량 재접수.
  const result = await processPickupRegistration({
    supabase,
    pickupRequestId,
    force: skipCancel,
    token,
    cfg,
  });

  return {
    ...result,
    requestStatus: base.requestStatus,
    reregistered: true,
    cancelledBoxes,
    skippedNotes,
  };
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

    const cfg = getCjConfig();
    const action = String(body.action || "register").toLowerCase();

    if (action === "cancel") {
      // 취소는 CJ 접수분이 있는 요청에서만 토큰이 필요 — 지연 발급 후 배치에서 재사용.
      // (접수 전 pending 취소가 CJ 토큰 장애에 막히지 않게. 발급 실패도 캐시돼 박스별 실패로 수집된다.)
      let tokenPromise = null;
      const getToken = () => {
        if (!tokenPromise) {
          tokenPromise = getOneDayToken(cfg);
        }
        return tokenPromise;
      };

      const results = [];
      for (const pickupRequestId of pickupRequestIds) {
        results.push(
          await processPickupCancellation({
            supabase,
            pickupRequestId,
            reason: body.reason,
            getToken,
            cfg,
          }),
        );
      }

      const failedCount = results.filter((result) => !result.success).length;
      return res.status(200).json({
        success: failedCount === 0,
        cancelledCount: results.filter((result) => result.status === "cancelled").length,
        cleanedCount: results.filter((result) => result.status === "cj_cleaned").length,
        cancelledBoxCount: results.reduce((sum, result) => sum + (result.cancelledBoxes || 0), 0),
        failedCount,
        results,
      });
    }

    if (action === "reregister") {
      // 재접수는 취소(CnclBook) → 접수(RegBook)를 한 흐름으로 — 토큰은 지연 발급 후 공유.
      let tokenPromise = null;
      const getToken = () => {
        if (!tokenPromise) {
          tokenPromise = getOneDayToken(cfg);
        }
        return tokenPromise;
      };

      const boxCount = Number.parseInt(String(body.boxCount ?? ""), 10);
      const desiredPickupDate = String(body.desiredPickupDate || "").trim() || null;
      if (desiredPickupDate && !/^\d{4}-\d{2}-\d{2}$/.test(desiredPickupDate)) {
        return res.status(400).json(
          makeErrorResponse({
            error: "desiredPickupDate must be YYYY-MM-DD.",
            code: "INVALID_PICKUP_DATE",
          }),
        );
      }

      const results = [];
      for (const pickupRequestId of pickupRequestIds) {
        results.push(
          await processPickupReregistration({
            supabase,
            pickupRequestId,
            boxCount: Number.isInteger(boxCount) ? boxCount : null,
            desiredPickupDate,
            skipCancel: Boolean(body.skipCancel),
            getToken,
            cfg,
          }),
        );
      }

      const failedCount = results.filter((result) => !result.success).length;
      return res.status(200).json({
        success: failedCount === 0,
        successCount: results.length - failedCount,
        failedCount,
        cancelledBoxCount: results.reduce((sum, result) => sum + (result.cancelledBoxes || 0), 0),
        results,
      });
    }

    if (action !== "register") {
      return res.status(400).json(
        makeErrorResponse({
          error: `Unknown action: ${action}`,
          code: "UNKNOWN_ACTION",
        }),
      );
    }

    // 1Day 토큰은 한 번만 발급해 배치 전체에서 재사용한다.
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
