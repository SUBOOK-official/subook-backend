import { createClient } from "@supabase/supabase-js";
import { createHmac, randomBytes } from "crypto";

// ── 솔라피(SOLAPI) 카카오 알림톡 API 설정 ──────────────────────
const SOLAPI_SEND_URL = "https://api.solapi.com/messages/v4/send";
const SOLAPI_REQUEST_TIMEOUT_MS = 5_000;
const SOLAPI_RETRY_COUNT = 1;

// ── 알림 유형 허용 목록 ──────────────────────────────────────
const VALID_NOTIFICATION_TYPES = new Set([
  "pickup_accepted",
  "arrived",
  "inspection_done",
  "sold",
  "settlement_done",
  "order_confirmed",
  "shipping_started",
  "delivery_done",
  "restock",
  // ⚠ admin_refund_order / 정산 회수 흐름에서 호출되는 type. 이전엔 set에 없어
  //   notifyRefundCompleted가 400 INVALID_NOTIFICATION_TYPE로 거부됐다.
  "refund_completed",
]);

// 카카오 알림톡 템플릿 코드 매핑
const TEMPLATE_CODES = {
  pickup_accepted: "SB_PICKUP_ACCEPTED",
  arrived: "SB_ARRIVED",
  inspection_done: "SB_INSPECTION_DONE",
  sold: "SB_SOLD",
  settlement_done: "SB_SETTLEMENT_DONE",
  order_confirmed: "SB_ORDER_CONFIRMED",
  shipping_started: "SB_SHIPPING_STARTED",
  delivery_done: "SB_DELIVERY_DONE",
  restock: "SB_RESTOCK",
  refund_completed: "SB_REFUND_COMPLETED",
};

// ── 메시지 본문 생성 ─────────────────────────────────────────
function buildMessageBody(type, vars) {
  switch (type) {
    case "pickup_accepted":
      return (
        `[수북] 수거 접수 완료\n` +
        `요청번호: ${vars.requestNumber}\n` +
        `교재: ${vars.itemCount}권\n` +
        `운송장: ${vars.trackingNumber || "배정 예정"}\n` +
        `택배기사가 1~2일 내에 수거합니다.`
      );

    case "arrived":
      return (
        `[수북] 교재 입고 완료\n` +
        `교재 ${vars.itemCount}권이 도착했습니다.\n` +
        `검수를 시작합니다.\n` +
        `결과는 1~3일 내에 알려드릴게요.`
      );

    case "inspection_done":
      return (
        `[수북] 검수 완료\n` +
        `${vars.inspectionResult || ""}\n` +
        `마이페이지에서 상세 내역을 확인하실 수 있습니다.`
      );

    case "sold":
      return (
        `[수북] 교재 판매 완료!\n` +
        `${vars.bookTitle}이(가) 판매되었습니다.\n` +
        `정산 예정일: ${vars.settlementDate}`
      );

    case "settlement_done":
      return (
        `[수북] 정산 완료\n` +
        `정산 금액: ${vars.amount}원\n` +
        `입금 계좌: ${vars.bankName} ****${vars.accountLast4}\n` +
        `마이페이지에서 확인하세요.`
      );

    case "order_confirmed":
      return (
        `[수북] 주문 확인\n` +
        `주문번호: ${vars.orderNumber}\n` +
        `${vars.itemSummary || ""}\n` +
        `결제 금액: ${vars.totalAmount}원\n` +
        `배송 예상: 2~3일`
      );

    case "shipping_started":
      return (
        `[수북] 배송 시작\n` +
        `운송장: CJ ${vars.trackingNumber}\n` +
        `배송추적: ${vars.trackingUrl || "https://www.cjlogistics.com/ko/tool/parcel/tracking"}`
      );

    case "delivery_done":
      return (
        `[수북] 교재 도착!\n` +
        `교재가 도착했습니다.\n` +
        `확인 후 구매확정 부탁드려요.\n` +
        `7일 후 자동 확정됩니다.`
      );

    // 카카오 검수 정책: 찜(단순 관심) 기반 문구는 광고성으로 반려됨.
    // 수신자 액션("재입고 알림을 신청")을 고정값으로 명시해야 알림톡 승인 가능.
    // 솔라피에 등록하는 템플릿 본문과 반드시 동일하게 유지할 것.
    case "restock":
      return (
        `[수북] 재입고 알림\n` +
        `회원님이 재입고 알림을 신청하신 교재 "${vars.productTitle}"이(가) 재입고되었습니다.\n` +
        `상품 페이지에서 바로 구매하실 수 있습니다.\n\n` +
        `※ 본 메시지는 회원님의 재입고 알림 신청에 의해 발송되는 정보성 메시지입니다.`
      );

    case "refund_completed":
      return (
        `[수북] 환불 완료\n` +
        `주문번호: ${vars.orderNumber}\n` +
        `환불 금액: ${vars.totalAmount}원\n` +
        `사유: ${vars.reason || "환불 처리"}\n` +
        `영업일 기준 2~5일 내 카드사·은행을 통해 환불됩니다.`
      );

    default:
      return "";
  }
}

// ── 사이트 내 알림 센터용 짧은 제목 ──────────────────────────
function buildInAppTitle(type, vars) {
  switch (type) {
    case "pickup_accepted": return "수거 접수가 완료되었어요";
    case "arrived":         return "교재 입고 완료";
    case "inspection_done": return "검수 결과 도착";
    case "sold":            return `"${vars.bookTitle ?? "내 교재"}" 판매 완료`;
    case "settlement_done": return "정산이 완료되었어요";
    case "order_confirmed": return "주문 결제가 확인되었어요";
    case "shipping_started":return "배송이 시작되었어요";
    case "delivery_done":   return "교재가 도착했어요";
    case "restock":         return `"${vars.productTitle ?? "알림 신청한 교재"}" 재입고`;
    case "refund_completed": return "환불이 완료되었어요";
    default:                return "알림";
  }
}

// ── 사이트 내 알림 클릭 시 이동할 URL ────────────────────────
function buildInAppRefUrl(type, refType, refId, vars) {
  if (type === "restock" && vars.productId) {
    return `/store/${vars.productId}`;
  }
  if (refType === "order" && refId) {
    return `/mypage#orders`;
  }
  if (refType === "pickup_request") {
    return `/mypage#sales`;
  }
  if (refType === "settlement") {
    return `/mypage#settlements`;
  }
  if (refType === "shipment") {
    return `/mypage#sales`;
  }
  return "/mypage";
}

// 알림톡 타입 → 솔라피 templateId 매핑. 템플릿 검수 통과 후 SOLAPI_TEMPLATE_IDS(JSON)로 주입.
//   예) SOLAPI_TEMPLATE_IDS={"pickup_accepted":"KA01TP...","arrived":"KA01TP...",...}
function getSolapiTemplateId(notificationType) {
  try {
    const map = JSON.parse(process.env.SOLAPI_TEMPLATE_IDS || "{}");
    return map[notificationType] || "";
  } catch {
    return "";
  }
}

// 솔라피 HMAC-SHA256 인증 헤더. signature = HMAC-SHA256(date+salt, apiSecret) hex.
function buildSolapiAuthHeader(apiKey, apiSecret) {
  const date = new Date().toISOString();
  const salt = randomBytes(32).toString("hex");
  const signature = createHmac("sha256", apiSecret).update(date + salt).digest("hex");
  return `HMAC-SHA256 apiKey=${apiKey}, date=${date}, salt=${salt}, signature=${signature}`;
}

// ── 솔라피(SOLAPI) 카카오 알림톡 발송 ─────────────────────────
async function sendKakaoAlimtalk({ recipientPhone, notificationType, templateVariables }) {
  const apiKey = process.env.SOLAPI_API_KEY;
  const apiSecret = process.env.SOLAPI_API_SECRET;
  const pfId = process.env.SOLAPI_PFID;
  const from = String(process.env.SOLAPI_FROM || "").replace(/\D/g, "");
  const templateId = getSolapiTemplateId(notificationType);

  if (!apiKey || !apiSecret || !pfId || !from) {
    return { success: false, error: "SOLAPI 환경변수 미설정 (API_KEY/SECRET/PFID/FROM)" };
  }
  if (!templateId) {
    return { success: false, error: `SOLAPI templateId 미설정: ${notificationType}` };
  }

  const to = String(recipientPhone || "").replace(/\D/g, "");
  if (!to) {
    return { success: false, error: "수신번호가 올바르지 않습니다." };
  }

  // 카카오 변수는 #{키} 형태, 값은 모두 문자열로.
  const variables = {};
  for (const [key, value] of Object.entries(templateVariables || {})) {
    variables[`#{${key}}`] = value === null || value === undefined ? "" : String(value);
  }

  const body = {
    message: {
      to,
      from,
      kakaoOptions: {
        pfId,
        templateId,
        variables,
        // 알림톡 실패 시 문자 대체발송 — 기본 비활성(추가 과금 방지). 켜려면 SOLAPI_ENABLE_SMS_FALLBACK=true
        disableSms: String(process.env.SOLAPI_ENABLE_SMS_FALLBACK || "").toLowerCase() !== "true",
      },
    },
  };

  for (let attempt = 0; attempt <= SOLAPI_RETRY_COUNT; attempt++) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), SOLAPI_REQUEST_TIMEOUT_MS);

      const response = await fetch(SOLAPI_SEND_URL, {
        method: "POST",
        headers: {
          Authorization: buildSolapiAuthHeader(apiKey, apiSecret),
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      const result = await response.json().catch(() => ({}));

      // 솔라피: 정상 접수 시 statusCode "2000". 실패 메시지 목록(failedMessageList)이 있으면 실패.
      const failed = Array.isArray(result?.failedMessageList) && result.failedMessageList.length > 0;
      const statusCode = result?.statusCode || result?.groupInfo?.status || "";
      const ok =
        response.ok &&
        !failed &&
        !result?.errorCode &&
        (statusCode === "" || statusCode === "2000" || String(statusCode).startsWith("2"));

      if (ok) {
        return { success: true, messageId: result?.messageId || result?.groupId || null };
      }

      const errorMsg =
        result?.failedMessageList?.[0]?.statusMessage ||
        result?.statusMessage ||
        result?.errorMessage ||
        result?.message ||
        `HTTP ${response.status}`;

      if (attempt < SOLAPI_RETRY_COUNT) continue;
      return { success: false, error: errorMsg };
    } catch (err) {
      if (attempt < SOLAPI_RETRY_COUNT) continue;
      const errorMsg =
        err.name === "AbortError"
          ? `솔라피 API 타임아웃 (${SOLAPI_REQUEST_TIMEOUT_MS}ms)`
          : err.message;
      return { success: false, error: errorMsg };
    }
  }
}

// ── 인증/설정 헬퍼 ───────────────────────────────────────────
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

function makeErrorResponse({ error, code, detail }) {
  const payload = { error: String(error || "Request failed."), code: String(code || "UNKNOWN") };
  if (detail) payload.detail = String(detail);
  return payload;
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

  return supabase;
}

// ── 메인 핸들러 ──────────────────────────────────────────────
export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json(makeErrorResponse({ error: "Method not allowed", code: "METHOD_NOT_ALLOWED" }));
  }

  const accessToken = parseBearerToken(req.headers.authorization);
  if (!accessToken) {
    return res.status(401).json(makeErrorResponse({ error: "Missing auth token", code: "MISSING_AUTH_TOKEN" }));
  }

  let supabase;
  const cronSecret = process.env.CRON_SECRET;

  // ⚠️ 인증 분기:
  //   1) Bearer가 CRON_SECRET과 일치하면 cron/internal 호출로 간주 → service_role client 발급
  //   2) 그 외는 어드민 토큰으로 검증
  if (cronSecret && accessToken === cronSecret) {
    const url =
      process.env.SUPABASE_URL ||
      process.env.SUPABASE_ADMIN_URL ||
      process.env.VITE_SUPABASE_ADMIN_URL ||
      process.env.VITE_SUPABASE_URL;
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;
    if (!url || !serviceKey) {
      return res.status(500).json(makeErrorResponse({ error: "Server misconfigured", code: "CONFIG_MISSING" }));
    }
    supabase = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  } else {
    try {
      supabase = await assertAdminUser(accessToken);
    } catch (err) {
      const status = err.statusCode || 500;
      return res.status(status).json(makeErrorResponse({ error: err.message, code: err.message }));
    }
  }

  // 요청 바디 파싱
  const {
    notificationType,
    recipientPhone,
    recipientName,
    recipientUserId,
    refType,
    refId,
    templateVariables,
  } = req.body || {};

  if (!notificationType || !VALID_NOTIFICATION_TYPES.has(notificationType)) {
    return res.status(400).json(makeErrorResponse({
      error: `Invalid notification type: ${notificationType}`,
      code: "INVALID_NOTIFICATION_TYPE",
    }));
  }

  if (!recipientPhone) {
    return res.status(400).json(makeErrorResponse({
      error: "recipientPhone is required",
      code: "MISSING_RECIPIENT_PHONE",
    }));
  }

  const templateCode = TEMPLATE_CODES[notificationType];
  const messageBody = buildMessageBody(notificationType, templateVariables || {});

  if (!messageBody) {
    return res.status(400).json(makeErrorResponse({
      error: "Failed to build message body",
      code: "TEMPLATE_ERROR",
    }));
  }

  // 알림톡 발송 (솔라피 — notificationType으로 templateId 매핑)
  const kakaoResult = await sendKakaoAlimtalk({
    recipientPhone,
    notificationType,
    templateVariables: templateVariables || {},
  });

  const logStatus = kakaoResult.success ? "sent" : "failed";

  // 발송 로그 저장
  const { error: logError } = await supabase
    .from("notification_logs")
    .insert({
      recipient_user_id: recipientUserId || null,
      recipient_phone: recipientPhone,
      recipient_name: recipientName || null,
      notification_type: notificationType,
      ref_type: refType || null,
      ref_id: refId || null,
      template_code: templateCode,
      template_variables: templateVariables || {},
      message_body: messageBody,
      status: logStatus,
      vendor_message_id: kakaoResult.messageId || null,
      error_message: kakaoResult.error || null,
      sent_at: kakaoResult.success ? new Date().toISOString() : null,
    });

  if (logError) {
    console.error("Failed to save notification log:", logError);
  }

  // 사이트 내 알림 센터에 미러링 (recipientUserId가 있을 때만)
  // 알림톡 발송 실패해도 사이트 내 알림은 노출 (사용자가 보장적으로 확인 가능)
  if (recipientUserId) {
    const inAppTitle = buildInAppTitle(notificationType, templateVariables || {});
    const inAppRefUrl = buildInAppRefUrl(notificationType, refType, refId, templateVariables || {});
    const { error: notifError } = await supabase.rpc("admin_create_member_notification", {
      p_user_id: recipientUserId,
      p_type: notificationType,
      p_title: inAppTitle,
      p_body: messageBody,
      p_ref_url: inAppRefUrl,
      p_ref_type: refType || null,
      p_ref_id: refId || null,
    });
    if (notifError) {
      console.error("Failed to create member_notification:", notifError);
    }
  }

  if (!kakaoResult.success) {
    return res.status(502).json({
      success: false,
      error: kakaoResult.error,
      code: "KAKAO_API_FAILURE",
      notificationType,
      messageBody,
      logSaved: !logError,
    });
  }

  return res.status(200).json({
    success: true,
    notificationType,
    messageId: kakaoResult.messageId,
    messageBody,
  });
}
