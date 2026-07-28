import { createClient } from "@supabase/supabase-js";

/**
 * CJ 배송 추적 단건 조회 (어드민 UI 온디맨드, 2026-07-28)
 *
 * AdminOrdersPage의 '배송조회' 버튼이 호출 — 운송장 번호 하나의 전체 스캔 이력을
 * CJ 상품추적 API(ReqOneGdsTrc)로 조회해 타임라인으로 돌려준다.
 *
 * 인증: 어드민 로그인 JWT (Bearer) → is_admin_user RPC 검증 (book-studio.js와 동일 패턴).
 * CJ 플러밍: cj-delivery-tracking.js(자동 배송완료 크론)와 동일 규격
 *   (V3.9.4: ReqOneDayToken → CJ-Gateway-APIKey 헤더 → ReqOneGdsTrc).
 * 응답 이벤트 필드(규격서 p.??: ReqOneGdsTrc 리턴): CRG_ST/CRG_ST_NM(화물상태),
 *   SCAN_YMD/SCAN_HOUR, DEALT_BRAN_NM/TEL(처리점소), DEALT_EMP_NM/TEL(처리사원 — 배송기사).
 * 화물상태 기초 코드(1.2.1): 01 집화지시 / 11 집화처리 / 12 미집화 / 41 간선상차 /
 *   42 간선하차 / 82 배송출발 / 84 미배송 / 91 배송완료
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

function getSupabaseConfig() {
  const url =
    process.env.SUPABASE_ADMIN_URL || process.env.VITE_SUPABASE_ADMIN_URL;
  const anonKey =
    process.env.SUPABASE_ADMIN_ANON_KEY || process.env.VITE_SUPABASE_ADMIN_ANON_KEY;
  return { url, anonKey };
}

function parseBearerToken(authHeader) {
  const raw = String(authHeader || "");
  const match = raw.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || "";
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

function joinUrl(baseUrl, endpoint) {
  const base = String(baseUrl || "").replace(/\/+$/, "");
  const path = String(endpoint || "").replace(/^\/+/, "");
  return `${base}/${path}`;
}

function buildCjHeaders(apiKey) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  if (apiKey) {
    headers["CJ-Gateway-APIKey"] = apiKey;
  }
  return headers;
}

async function requestJsonWithRetry(url, options) {
  let lastError = null;

  for (let attempt = 0; attempt <= CJ_RETRY_COUNT; attempt += 1) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), CJ_REQUEST_TIMEOUT_MS);

    try {
      const response = await fetch(url, { ...options, signal: controller.signal });
      clearTimeout(timeoutId);

      const text = await response.text();
      let body = null;
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = { rawText: text };
      }

      if (response.ok) {
        return body;
      }
      const error = new Error(`CJ API HTTP ${response.status}`);
      error.code = "CJ_HTTP_ERROR";
      if (attempt < CJ_RETRY_COUNT && (response.status === 408 || response.status === 429 || response.status >= 500)) {
        lastError = error;
        continue;
      }
      throw error;
    } catch (error) {
      clearTimeout(timeoutId);
      lastError = error;
      const isTimeout = error?.name === "AbortError";
      if (attempt < CJ_RETRY_COUNT && isTimeout) {
        continue;
      }
      throw isTimeout ? Object.assign(new Error("CJ 응답 시간 초과"), { code: "CJ_TIMEOUT" }) : error;
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
  return requestJsonWithRetry(joinUrl(cfg.baseUrl, endpoint), {
    method: "POST",
    headers: buildCjHeaders(apiKey),
    body: JSON.stringify({ DATA: data }),
  });
}

async function getOneDayToken(cfg) {
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

// 스캔 시각 표시용 포맷. ⚠ 규격서 타입은 VARCHAR(8)/(6)이지만 실제 응답 예시는
// "2020-12-31"/"10:34:02"처럼 구분자 포함(2026-07-28 실측 동일) — 숫자만 추출해 양쪽 다 처리.
function formatScanTime(ymd, hour) {
  const d = String(ymd || "").trim().replace(/\D/g, "");
  const t = String(hour || "").trim().replace(/\D/g, "");
  if (d.length !== 8) return String(ymd || "").trim();
  const datePart = `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}`;
  if (t.length < 4) return datePart;
  return `${datePart} ${t.slice(0, 2)}:${t.slice(2, 4)}`;
}

export default async function handler(req, res) {
  if (req.method !== "GET") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  try {
    const token = parseBearerToken(req.headers.authorization);
    if (!token) {
      return res.status(401).json({ error: "인증 토큰이 없습니다.", code: "MISSING_AUTH_TOKEN" });
    }
    await assertAdminUser(token);
  } catch (err) {
    const status = err?.statusCode || 401;
    return res.status(status).json({ error: err?.message || "Unauthorized" });
  }

  const invcNo = String(req.query?.invcNo ?? "").replace(/\D/g, "");
  if (!invcNo || invcNo.length < 10 || invcNo.length > 20) {
    return res.status(400).json({ error: "운송장 번호가 올바르지 않습니다.", code: "INVALID_INVC_NO" });
  }

  // 로컬/모의 환경용 — 실제 CJ 미연결 상태에서 UI 확인
  if (isMockMode()) {
    return res.status(200).json({
      success: true,
      invcNo,
      mock: true,
      delivered: false,
      events: [
        { at: "2026-07-28 09:10", statusCode: "11", statusText: "집화처리(mock)", branchName: "광주지점", branchTel: "", workerName: "", workerTel: "" },
        { at: "2026-07-28 14:22", statusCode: "82", statusText: "배송출발(mock)", branchName: "서울강남지점", branchTel: "", workerName: "김기사", workerTel: "010-0000-0000" },
      ],
    });
  }

  try {
    const cfg = getCjConfig();
    if (!cfg.custId) {
      return res.status(500).json({ error: "CJ 고객사 코드가 설정되지 않았습니다.", code: "CJ_CUST_ID_MISSING" });
    }

    const cjToken = await getOneDayToken(cfg);
    const body = await postCj(cfg, cfg.trackingEndpoint, {
      CLNTNUM: cfg.custId,
      INVC_NO: invcNo,
      TOKEN_NUM: cjToken,
    }, cjToken);

    if (!isCjSuccess(body)) {
      const message = getCjMessage(body);
      // 집화 스캔 전에는 원래 데이터가 없다 (cj-delivery-tracking.js와 동일 처리)
      if (/no data/i.test(message)) {
        return res.status(200).json({
          success: true,
          invcNo,
          events: [],
          noData: true,
          message: "아직 추적 정보가 없어요. 기사님이 집화 스캔을 하기 전이에요.",
        });
      }
      return res.status(502).json({ error: message || "CJ 배송 추적 조회에 실패했습니다.", code: "CJ_TRACKING_FAILED" });
    }

    const rawArray = Array.isArray(body?.DATA)
      ? body.DATA
      : Array.isArray(body?.DATA?.ARRAY)
        ? body.DATA.ARRAY
        : [];

    const events = rawArray
      .filter((e) => e && typeof e === "object")
      .map((e) => {
        // DEALT_BRAN_TEL은 "점소명(010-1234-5678)" 형태로 병합돼 오는 경우가 있어(실측)
        // 전화번호만 추출한다. 없으면 null.
        const branchTelRaw = String(e.DEALT_BRAN_TEL || "").trim();
        const branchTelMatch = branchTelRaw.match(/(\d{2,4}-\d{3,4}-\d{4})/);
        return {
          // 정렬 키 — 숫자만 이어붙여 YYYYMMDDHHMMSS (형식 편차 무관)
          sortKey: `${String(e.SCAN_YMD || "").replace(/\D/g, "")}${String(e.SCAN_HOUR || "").replace(/\D/g, "").padEnd(6, "0")}`,
          at: formatScanTime(e.SCAN_YMD, e.SCAN_HOUR),
          statusCode: e.CRG_ST != null ? String(e.CRG_ST).trim() : null,
          statusText: String(e.CRG_ST_NM || "").trim() || null,
          branchName: String(e.DEALT_BRAN_NM || "").trim() || null,
          branchTel: branchTelMatch ? branchTelMatch[1] : null,
          workerName: String(e.DEALT_EMP_NM || "").trim() || null,
          workerTel: String(e.DEALT_EMP_TEL || "").trim() || null,
        };
      })
      .sort((a, b) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0))
      .map(({ sortKey, ...rest }) => rest);

    const latest = events.length > 0 ? events[events.length - 1] : null;
    const delivered =
      latest != null &&
      (String(latest.statusCode || "") === DELIVERED_STATUS_CODE ||
        /배송완료|배달완료/.test(String(latest.statusText || "")));

    return res.status(200).json({ success: true, invcNo, events, latest, delivered });
  } catch (err) {
    console.error("cj-track-waybill error:", err?.message || err);
    const message =
      err?.code === "CJ_CONFIG_MISSING" || err?.code === "CJ_CUST_ID_MISSING"
        ? "CJ 연동 설정이 누락되었습니다."
        : err?.message || "배송 조회 중 오류가 발생했습니다.";
    return res.status(502).json({ error: message, code: err?.code || "CJ_ERROR" });
  }
}
