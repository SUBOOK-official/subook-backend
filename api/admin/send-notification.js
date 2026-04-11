import { createClient } from "@supabase/supabase-js";

// ── 카카오 알림톡 API 설정 ──────────────────────────────────
const KAKAO_BIZ_API_URL = "https://kakaotalk-bizmessage.api.nhncloudservice.com/alimtalk/v2.3/appkeys";
const KAKAO_REQUEST_TIMEOUT_MS = 5_000;
const KAKAO_RETRY_COUNT = 1;

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
        `${(vars.items || []).map((item) => `▸ ${item.title}: ${item.grade} / ${item.price}`).join("\n")}\n` +
        `마이페이지에서 상세 확인하세요.`
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
        `${vars.firstItemTitle}${vars.extraCount > 0 ? ` 외 ${vars.extraCount}건` : ""}\n` +
        `결제: ${vars.totalAmount}원\n` +
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

    default:
      return "";
  }
}

// ── 카카오 알림톡 API 호출 ───────────────────────────────────
async function sendKakaoAlimtalk({ recipientPhone, templateCode, templateVariables }) {
  const appKey = process.env.KAKAO_ALIMTALK_APP_KEY;
  const secretKey = process.env.KAKAO_ALIMTALK_SECRET_KEY;
  const senderKey = process.env.KAKAO_ALIMTALK_SENDER_KEY;

  if (!appKey || !secretKey || !senderKey) {
    return { success: false, error: "KAKAO_ALIMTALK 환경변수 미설정" };
  }

  // 전화번호 정규화 (하이픈 제거, 국가번호 추가)
  const phone = recipientPhone.replace(/-/g, "").replace(/^0/, "82");

  const body = {
    senderKey,
    templateCode,
    recipientList: [
      {
        recipientNo: phone,
        templateParameter: templateVariables || {},
      },
    ],
  };

  const url = `${KAKAO_BIZ_API_URL}/${appKey}/messages`;

  for (let attempt = 0; attempt <= KAKAO_RETRY_COUNT; attempt++) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), KAKAO_REQUEST_TIMEOUT_MS);

      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json;charset=UTF-8",
          "X-Secret-Key": secretKey,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      const result = await response.json();

      if (response.ok && result.header?.isSuccessful) {
        const messageId =
          result.message?.requestId ||
          result.sendResults?.[0]?.requestId ||
          null;
        return { success: true, messageId };
      }

      const errorMsg =
        result.header?.resultMessage ||
        result.message?.resultMessage ||
        `HTTP ${response.status}`;

      if (attempt < KAKAO_RETRY_COUNT) continue;
      return { success: false, error: errorMsg };
    } catch (err) {
      if (attempt < KAKAO_RETRY_COUNT) continue;
      const errorMsg =
        err.name === "AbortError"
          ? `카카오 API 타임아웃 (${KAKAO_REQUEST_TIMEOUT_MS}ms)`
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
  try {
    supabase = await assertAdminUser(accessToken);
  } catch (err) {
    const status = err.statusCode || 500;
    return res.status(status).json(makeErrorResponse({ error: err.message, code: err.message }));
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

  // 알림톡 발송
  const kakaoResult = await sendKakaoAlimtalk({
    recipientPhone,
    templateCode,
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
