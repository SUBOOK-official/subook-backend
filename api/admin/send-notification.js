import { createClient } from "@supabase/supabase-js";
import { createHmac, randomBytes } from "crypto";

// ── 솔라피(SOLAPI) 카카오 알림톡 API 설정 ──────────────────────
const SOLAPI_SEND_URL = "https://api.solapi.com/messages/v4/send";
const SOLAPI_REQUEST_TIMEOUT_MS = 5_000;
const SOLAPI_RETRY_COUNT = 1;

// ── 알림 유형 허용 목록 ──────────────────────────────────────
// 2026-08-09 템플릿 v2 전환: sold(판매완료)·arrived(입고완료)는 폐지됨.
// 과거 로그 재발송 시 두 타입은 400 INVALID_NOTIFICATION_TYPE — 의도된 동작.
const VALID_NOTIFICATION_TYPES = new Set([
  "pickup_accepted",
  "inspection_done",
  "settlement_done",
  "order_confirmed",
  "shipping_started",
  "delivery_done",
  "restock",
  // ⚠ admin_refund_order / 정산 회수 흐름에서 호출되는 type. 이전엔 set에 없어
  //   notifyRefundCompleted가 400 INVALID_NOTIFICATION_TYPE로 거부됐다.
  "refund_completed",
]);

// 카카오 알림톡 템플릿 코드 매핑 (notification_logs.template_code용 내부 라벨)
const TEMPLATE_CODES = {
  pickup_accepted: "SB_PICKUP_ACCEPTED",
  inspection_done: "SB_INSPECTION_DONE",
  settlement_done: "SB_SETTLEMENT_DONE",
  order_confirmed: "SB_ORDER_CONFIRMED",
  shipping_started: "SB_SHIPPING_STARTED",
  delivery_done: "SB_DELIVERY_DONE",
  restock: "SB_RESTOCK",
  refund_completed: "SB_REFUND_COMPLETED",
};

// ── 메시지 본문 생성 ─────────────────────────────────────────
// ⚠ 솔라피에 등록된 v2 템플릿 본문과 반드시 동일하게 유지할 것 (줄바꿈 포함).
// 실제 수신 내용은 카카오가 등록 템플릿 + 변수 치환으로 렌더하므로, 이 함수는
// notification_logs.message_body와 사이트 내 알림 본문을 발송 내용과 일치시키는 용도다.
function buildMessageBody(type, vars) {
  switch (type) {
    case "pickup_accepted":
      return (
        `[수북(SUBOOK) 교재 수거 접수 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `교재 수거 신청이 정상적으로 접수되었습니다.\n` +
        `► 요청번호 : ${vars.requestNumber}\n` +
        `► 수거 교재 : ${vars.itemCount}권\n` +
        `► 운송장 : ${vars.trackingNumber || "배정 예정"}\n` +
        `택배기사가 접수일로부터 1~2일 이내에 방문하여 교재를 수거할 예정입니다.\n` +
        `택배기사 방문 전까지 교재가 훼손되지 않도록 안전하게 포장해 주시고, 빠른 시일 내에 택배기사가 수거할 수 있는 장소에 준비해 주세요.\n` +
        `택배사 사정 및 방문 일정에 따라 수거 시간이 다소 변경될 수 있습니다.`
      );

    // v2: 등급·가격 상세(#{inspectionResult}) 제거 — 상세는 마이페이지에서 확인.
    case "inspection_done":
      return (
        `[수북(SUBOOK) 검수 완료 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `보내주신 교재의 검수가 완료되었습니다.\n` +
        `검수 결과 및 상세 내역은 수북(SUBOOK) 마이페이지에서 확인하실 수 있습니다.\n` +
        `검수 결과에 대한 문의사항이 있으신 경우 고객센터를 통해 문의해 주세요.`
      );

    case "settlement_done":
      return (
        `[수북(SUBOOK) 정산 완료 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `판매하신 교재에 대한 정산이 완료되어 안내드립니다.\n` +
        `► 정산 금액 : ${vars.amount}원\n` +
        `► 입금 계좌 : ${vars.bankName} ****${vars.accountLast4}\n` +
        `정산 금액은 위 계좌로 입금 처리되었습니다.\n` +
        `정산 내역은 수북(SUBOOK) 마이페이지에서 자세히 확인하실 수 있습니다.\n` +
        `정산 관련 문의사항이 있으신 경우 수북(SUBOOK) 고객센터로 문의해 주세요.`
      );

    case "order_confirmed":
      return (
        `[수북(SUBOOK) 주문 확인 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `고객님의 주문이 정상적으로 확인되었습니다.\n` +
        `► 주문번호 : ${vars.orderNumber}\n` +
        `► 상품명 : ${vars.itemSummary || ""}\n` +
        `► 결제 금액 : ${vars.totalAmount}원\n` +
        `► 예상 배송 소요기간 : 2~3일\n` +
        `배송은 결제 및 주문 확인 후 순차적으로 진행됩니다.\n` +
        `택배사 사정 및 날씨, 도로 상황 등에 따라 배송 예정일은 변경될 수 있습니다.\n` +
        `주문해 주셔서 감사합니다.`
      );

    case "shipping_started":
      return (
        `[수북(SUBOOK) 배송 시작 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `주문하신 교재가 발송되어 배송이 시작되었습니다.\n` +
        `► 운송장 번호 : CJ대한통운 ${vars.trackingNumber}\n` +
        `택배사 사정 및 날씨, 도로 상황 등에 따라 배송 예정일은 변경될 수 있습니다.\n` +
        `배송 현황은 운송장 번호를 통해 확인하실 수 있습니다.\n` +
        `교재가 안전하게 도착할 수 있도록 최선을 다하겠습니다.`
      );

    case "delivery_done":
      return (
        `[수북(SUBOOK) 교재 도착 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `주문하신 교재의 배송이 완료되었습니다.\n` +
        `교재를 수령하신 후 상품 상태를 확인하시고 구매확정을 부탁드립니다.\n` +
        `구매확정을 완료하지 않으신 경우 배송완료일로부터 7일 후 자동으로 구매확정 처리됩니다.`
      );

    // 카카오 검수 정책: 찜(단순 관심) 기반 문구는 광고성으로 반려됨.
    // 수신자 액션("재입고 알림을 신청")을 고정값으로 명시해야 알림톡 승인 가능.
    case "restock":
      return (
        `[수북(SUBOOK) 재입고 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `회원님께서 재입고 알림을 신청하신 교재가 재입고되어 안내드립니다.\n` +
        `► 상품명 : ${vars.productTitle}\n` +
        `재입고된 상품은 상품 페이지에서 바로 구매하실 수 있습니다.\n` +
        `※ 본 메시지는 회원님의 재입고 알림 신청에 의해 발송되는 정보성 메시지입니다.`
      );

    case "refund_completed":
      return (
        `[수북(SUBOOK) 환불 완료 안내]\n` +
        `안녕하세요, 수북(SUBOOK)입니다.\n` +
        `고객님의 주문에 대한 환불 처리가 완료되었습니다.\n` +
        `► 주문번호 : ${vars.orderNumber}\n` +
        `► 환불 금액 : ${vars.totalAmount}원\n` +
        `► 환불 사유 : ${vars.reason || "환불 처리"}\n` +
        `환불 금액은 결제 수단에 따라 영업일 기준 1~5일 이내 카드사 또는 은행을 통해 환불될 예정입니다.\n` +
        `카드사 및 은행의 사정에 따라 실제 환불 완료 시점은 다소 차이가 있을 수 있습니다.\n` +
        `환불 관련 문의사항이 있으신 경우 수북(SUBOOK) 고객센터로 문의해 주세요.`
      );

    default:
      return "";
  }
}

// ── 사이트 내 알림 센터용 짧은 제목 ──────────────────────────
function buildInAppTitle(type, vars) {
  switch (type) {
    case "pickup_accepted": return "수거 접수가 완료되었어요";
    case "inspection_done": return "검수 결과 도착";
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

// ── 멱등성 키 ────────────────────────────────────────────────
// 같은 비즈니스 이벤트(타입:참조:수신번호)의 중복 발송을 DB unique 인덱스로 차단한다.
// - ref가 있는 발송(운영 트리거 전부): 이벤트당 1회. 수신번호가 바뀌면(번호 정정 후 재발송) 새 키.
// - ref가 없는 발송(테스트 등): 분 단위 버킷으로 연타만 방지.
// - allowDuplicate=true(향후 재전송 기능용): 키 없이 발송 → 중복 검사 우회.
function buildIdempotencyKey({ notificationType, refType, refId, toDigits, allowDuplicate }) {
  if (allowDuplicate) {
    return null;
  }
  if (refType && refId !== null && refId !== undefined && refId !== "") {
    return `${notificationType}:${refType}:${refId}:${toDigits}`;
  }
  const minuteBucket = new Date().toISOString().slice(0, 16); // YYYY-MM-DDTHH:MM
  return `${notificationType}:phone:${toDigits}:${minuteBucket}`;
}

// pending 선점 후 함수가 죽어 키가 영구 점유되는 것을 방지 — 이 시간 지난 pending은 회수해 재발송
const STALE_PENDING_RECLAIM_MS = 10 * 60 * 1000;

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
    allowDuplicate,
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

  // ── 멱등성 가드: 발송 전에 pending 로그를 idempotency_key로 선점 ──
  // 같은 이벤트의 두 번째 시도(더블클릭·일괄 재실행·동시 요청)는 unique 충돌로 걸러진다.
  const toDigits = String(recipientPhone).replace(/\D/g, "");
  const idempotencyKey = buildIdempotencyKey({
    notificationType,
    refType,
    refId,
    toDigits,
    allowDuplicate: allowDuplicate === true,
  });

  const logRow = {
    recipient_user_id: recipientUserId || null,
    recipient_phone: recipientPhone,
    recipient_name: recipientName || null,
    notification_type: notificationType,
    ref_type: refType || null,
    ref_id: refId || null,
    template_code: templateCode,
    template_variables: templateVariables || {},
    message_body: messageBody,
  };

  let pendingRowId = null;

  const { data: pendingRow, error: pendingInsertError } = await supabase
    .from("notification_logs")
    .insert({ ...logRow, status: "pending", idempotency_key: idempotencyKey })
    .select("id")
    .single();

  if (!pendingInsertError) {
    pendingRowId = pendingRow?.id ?? null;
  } else if (pendingInsertError.code === "23505" && idempotencyKey) {
    // 동일 이벤트가 이미 발송됐거나 진행 중.
    // 단, 오래된 pending(선점 후 함수가 죽은 잔재)은 회수해서 발송을 이어간다.
    const { data: existing } = await supabase
      .from("notification_logs")
      .select("id, status, created_at")
      .eq("idempotency_key", idempotencyKey)
      .maybeSingle();

    const isStalePending =
      existing?.status === "pending" &&
      existing?.created_at &&
      Date.now() - new Date(existing.created_at).getTime() > STALE_PENDING_RECLAIM_MS;

    if (isStalePending) {
      pendingRowId = existing.id;
    } else {
      return res.status(200).json({
        success: true,
        deduped: true,
        existingStatus: existing?.status ?? "sent",
        notificationType,
        messageBody,
      });
    }
  } else {
    // 로그 선점 실패(일시 오류 등)는 발송을 막지 않는다 — 발송 후 legacy 방식으로 기록 시도
    console.error("Failed to reserve notification log:", pendingInsertError);
  }

  // 알림톡 발송 (솔라피 — notificationType으로 templateId 매핑)
  const kakaoResult = await sendKakaoAlimtalk({
    recipientPhone,
    notificationType,
    templateVariables: templateVariables || {},
  });

  const logStatus = kakaoResult.success ? "sent" : "failed";

  // 발송 결과 기록. 실패 시 idempotency_key를 반납해 같은 이벤트의 재시도를 허용한다.
  let logError = null;

  if (pendingRowId) {
    const { error: updateError } = await supabase
      .from("notification_logs")
      .update({
        status: logStatus,
        vendor_message_id: kakaoResult.messageId || null,
        error_message: kakaoResult.error || null,
        sent_at: kakaoResult.success ? new Date().toISOString() : null,
        ...(kakaoResult.success ? {} : { idempotency_key: null }),
      })
      .eq("id", pendingRowId);
    logError = updateError;
  } else {
    const { error: insertError } = await supabase
      .from("notification_logs")
      .insert({
        ...logRow,
        status: logStatus,
        vendor_message_id: kakaoResult.messageId || null,
        error_message: kakaoResult.error || null,
        sent_at: kakaoResult.success ? new Date().toISOString() : null,
        idempotency_key: null,
      });
    logError = insertError;
  }

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
