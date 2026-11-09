import { createClient } from "@supabase/supabase-js";
import {
  IlseongApiError,
  createIlseongClient,
  getIlseongConfig,
  isValidRef,
  maskAppCode,
  syncOrder,
} from "../_lib/ilseongPartner.js";

/**
 * 일성월심 앱 코드 — 대기열 처리 크론 + 관리 API
 *
 * 크론(매분, Authorization: Bearer CRON_SECRET, GET):
 *   ILSEONG_API_BASE_URL·ILSEONG_PARTNER_SECRET가 없으면 앱 서버를 부르지 않고, 켜져 있던 판매만 끈다.
 *   있으면 ilseong_app_jobs에서 주문을 하나씩 가져와 발급 → 환불 폐기 → 알림톡 순으로 맞춘다.
 *   실패는 ilseong_app_finish_job이 1·2·4…분(최대 6시간) 간격으로 다시 잡고, 12회 넘으면 운영 경보.
 *
 * 관리 API(관리자 로그인 토큰):
 *   GET  ?action=overview                         연결 여부·설정·대기열·앱 패키지 상품
 *   POST {action:"save_settings", salesEnabled, refundPolicy, appDownloadUrl}
 *   POST {action:"order", orderNumber}            주문의 코드 상태(코드는 가려서)
 *   POST {action:"retry", orderId}                지금 다시 처리
 *   POST {action:"refresh", orderId}              앱 서버 상태(등록 여부) 다시 읽기
 *   POST {action:"reissue", orderId, lineRef}     등록 전 코드를 새 코드로 바꾸고 다시 보내기
 *   POST {action:"resend", orderId}               알림톡 다시 보내기(중복 허용)
 *
 * 코드 원문은 응답에 담지 않는다(주문자·서버만 읽는다).
 */

const RUN_BUDGET_MS = 20_000;
const MAX_JOBS_PER_RUN = 25;

function makeErrorResponse(error, code) {
  return { error: String(error || "Request failed."), code: String(code || "UNKNOWN") };
}

function parseBearerToken(authHeader) {
  const match = String(authHeader || "").match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || "";
}

function createServiceClient() {
  // service_role은 VITE_* 키 폴백 금지(클라이언트 번들 위험) — URL만 폴백
  const url =
    process.env.SUPABASE_URL ||
    process.env.SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;
  if (!url || !serviceKey) return null;
  return createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function assertAdmin(accessToken) {
  const url = process.env.SUPABASE_ADMIN_URL || process.env.VITE_SUPABASE_ADMIN_URL;
  const anonKey = process.env.SUPABASE_ADMIN_ANON_KEY || process.env.VITE_SUPABASE_ADMIN_ANON_KEY;
  if (!url || !anonKey) {
    const error = new Error("SUPABASE_CONFIG_MISSING");
    error.statusCode = 500;
    throw error;
  }
  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userResult, error: userError } = await userClient.auth.getUser(accessToken);
  if (userError || !userResult?.user) {
    const error = new Error("UNAUTHORIZED");
    error.statusCode = 401;
    throw error;
  }
  const { data: isAdmin, error: adminError } = await userClient.rpc("is_admin_user");
  if (adminError || !isAdmin) {
    const error = new Error("FORBIDDEN");
    error.statusCode = 403;
    throw error;
  }
  return { userId: userResult.user.id };
}

function rpcCaller(service) {
  return async (name, args) => {
    const { data, error } = await service.rpc(name, args);
    if (error) throw new Error(`${name}: ${error.message}`);
    return data;
  };
}

function selfBaseUrl(req) {
  const protocol = req.headers["x-forwarded-proto"] || "https";
  const host = req.headers["x-forwarded-host"] || req.headers.host;
  return `${protocol}://${host}`;
}

// 알림톡은 기존 send-notification(솔라피)을 그대로 쓴다. 코드·수신번호는 그쪽이 주문에서 다시 읽는다.
function makeNotifier({ baseUrl, cronSecret, fetchImpl = globalThis.fetch }) {
  return async ({ order, allowDuplicate }) => {
    if (!cronSecret) return { ok: false, error: "CRON_SECRET 미설정" };
    try {
      const response = await fetchImpl(`${baseUrl}/api/admin/send-notification`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${cronSecret}` },
        body: JSON.stringify({
          notificationType: "app_code",
          refType: "order",
          refId: order.id,
          recipientPhone: order.recipient_phone,
          allowDuplicate: Boolean(allowDuplicate),
          templateVariables: {},
        }),
      });
      const data = await response.json().catch(() => ({}));
      if (response.ok && data?.success) return { ok: true, deduped: Boolean(data.deduped) };
      return { ok: false, error: data?.error || `HTTP ${response.status}` };
    } catch (err) {
      return { ok: false, error: err?.message || String(err) };
    }
  };
}

function maskLines(lines) {
  return (Array.isArray(lines) ? lines : []).map((line) => ({
    line_ref: line.line_ref,
    order_item_id: line.order_item_id,
    title: line.title,
    app_product_code: line.app_product_code,
    status: line.status,
    code_masked: maskAppCode(line.code),
    issued_at: line.issued_at,
    redeemed_at: line.redeemed_at,
    reissued_at: line.reissued_at,
    notified_at: line.notified_at,
    revoke_requested_at: line.revoke_requested_at,
    revoke_access: line.revoke_access,
    revoke_processed_at: line.revoke_processed_at,
  }));
}

function maskContext(context) {
  if (!context?.order) return null;
  const { order } = context;
  return {
    order: { id: order.id, order_number: order.order_number, status: order.status, payment_status: order.payment_status },
    lines: maskLines(context.lines),
  };
}

// ── 크론: 대기열 처리 ─────────────────────────────────────────
export async function runQueue({ service, config, notify, clientFactory = createIlseongClient, now = () => Date.now() }) {
  const rpc = rpcCaller(service);
  if (!config.configured) {
    const disabled = await rpc("ilseong_app_disable_sales", {});
    return { configured: false, processed: 0, salesDisabled: disabled === true };
  }

  const client = clientFactory({ baseUrl: config.baseUrl, secret: config.secret });
  const startedAt = now();
  const results = [];
  while (results.length < MAX_JOBS_PER_RUN && now() - startedAt < RUN_BUDGET_MS) {
    const job = await rpc("ilseong_app_claim_job", {});
    if (!job?.id) break;
    let errorMessage = null;
    try {
      const context = await rpc("ilseong_app_order_context", { p_order_id: job.order_id });
      await syncOrder({ context, client, rpc, notify });
    } catch (err) {
      errorMessage = err instanceof IlseongApiError ? err.message : `처리 오류: ${err?.message || err}`;
      console.error("ilseong-app-codes job failed", job.id, job.order_id, errorMessage);
    }
    const finished = await rpc("ilseong_app_finish_job", { p_job_id: job.id, p_error: errorMessage });
    results.push({ jobId: job.id, orderId: job.order_id, ok: !errorMessage, status: finished?.status ?? null });
  }
  return {
    configured: true,
    processed: results.length,
    failed: results.filter((item) => !item.ok).length,
    results,
  };
}

// ── 관리 API ─────────────────────────────────────────────────
async function loadOrderContext(rpc, orderId) {
  const id = Number(orderId);
  if (!Number.isInteger(id) || id <= 0) {
    const error = new Error("주문 id가 올바르지 않습니다.");
    error.statusCode = 400;
    throw error;
  }
  const context = await rpc("ilseong_app_order_context", { p_order_id: id });
  if (!context?.order) {
    const error = new Error("주문을 찾을 수 없습니다.");
    error.statusCode = 404;
    throw error;
  }
  return context;
}

function requireConfigured(config) {
  if (!config.configured) {
    const error = new Error("앱 서버 연결 설정(ILSEONG_API_BASE_URL·ILSEONG_PARTNER_SECRET)이 없습니다.");
    error.statusCode = 409;
    error.code = "ILSEONG_NOT_CONFIGURED";
    throw error;
  }
}

export async function handleAdminAction({ action, body, service, config, notify, userId, clientFactory = createIlseongClient }) {
  const rpc = rpcCaller(service);

  if (action === "overview") {
    const overview = await rpc("ilseong_app_admin_overview", {});
    return { configured: config.configured, ...overview };
  }

  if (action === "save_settings") {
    const salesEnabled = body.salesEnabled === true;
    if (salesEnabled) requireConfigured(config);
    const settings = await rpc("ilseong_app_save_settings", {
      p_sales_enabled: salesEnabled,
      p_refund_policy: body.refundPolicy ?? null,
      p_app_download_url: body.appDownloadUrl ?? null,
      p_actor: userId ?? null,
    });
    return { configured: config.configured, settings };
  }

  if (action === "order") {
    const orderId = await rpc("ilseong_app_find_order", { p_order_number: String(body.orderNumber || "") });
    if (!orderId) {
      const error = new Error("주문을 찾을 수 없습니다.");
      error.statusCode = 404;
      throw error;
    }
    return maskContext(await loadOrderContext(rpc, orderId));
  }

  if (action === "retry") {
    const context = await loadOrderContext(rpc, body.orderId);
    await rpc("ilseong_app_retry_order", { p_order_id: context.order.id });
    return { ok: true };
  }

  if (action === "refresh") {
    requireConfigured(config);
    const context = await loadOrderContext(rpc, body.orderId);
    const client = clientFactory({ baseUrl: config.baseUrl, secret: config.secret });
    try {
      const status = await client.getOrder(context.order.order_number);
      await rpc("ilseong_app_record_lines", { p_order_id: context.order.id, p_lines: status?.lines ?? [], p_reissued: false });
    } catch (err) {
      if (!(err instanceof IlseongApiError && err.code === "ORDER_NOT_FOUND")) throw err;
    }
    return maskContext(await loadOrderContext(rpc, context.order.id));
  }

  if (action === "reissue") {
    requireConfigured(config);
    const context = await loadOrderContext(rpc, body.orderId);
    const lineRef = String(body.lineRef || "");
    const line = context.lines.find((item) => item.line_ref === lineRef);
    if (!line || !isValidRef(lineRef)) {
      const error = new Error("주문 줄을 찾을 수 없습니다.");
      error.statusCode = 404;
      throw error;
    }
    if (line.status !== "issued" || line.revoke_requested_at) {
      const error = new Error("앱에 등록하기 전인 코드만 새 코드로 바꿀 수 있습니다.");
      error.statusCode = 409;
      throw error;
    }
    const client = clientFactory({ baseUrl: config.baseUrl, secret: config.secret });
    const response = await client.reissue(context.order.order_number, lineRef);
    await rpc("ilseong_app_record_lines", { p_order_id: context.order.id, p_lines: response?.lines ?? [], p_reissued: true });
    const sent = await notify({ order: context.order, allowDuplicate: true });
    if (sent.ok) {
      await rpc("ilseong_app_mark_notified", { p_order_id: context.order.id, p_line_refs: [lineRef] });
    } else {
      // 알림은 대기열이 다시 시도한다(재발급 코드라 중복 허용으로 보냄)
      await rpc("ilseong_app_retry_order", { p_order_id: context.order.id });
    }
    return { ...maskContext(await loadOrderContext(rpc, context.order.id)), notified: sent.ok, notifyError: sent.ok ? null : sent.error };
  }

  if (action === "resend") {
    const context = await loadOrderContext(rpc, body.orderId);
    const active = context.lines.filter((line) => line.code && ["issued", "redeemed"].includes(line.status) && !line.revoke_requested_at);
    if (active.length === 0) {
      const error = new Error("보낼 앱 코드가 없습니다.");
      error.statusCode = 409;
      throw error;
    }
    const sent = await notify({ order: context.order, allowDuplicate: true });
    if (sent.ok) {
      await rpc("ilseong_app_mark_notified", { p_order_id: context.order.id, p_line_refs: active.map((line) => line.line_ref) });
    }
    return { ...maskContext(await loadOrderContext(rpc, context.order.id)), notified: sent.ok, notifyError: sent.ok ? null : sent.error };
  }

  const error = new Error(`알 수 없는 action: ${action}`);
  error.statusCode = 400;
  throw error;
}

export default async function handler(req, res) {
  const token = parseBearerToken(req.headers.authorization);
  const cronSecret = process.env.CRON_SECRET;
  const service = createServiceClient();
  if (!service) {
    return res.status(500).json(makeErrorResponse("Missing Supabase configuration", "CONFIG_MISSING"));
  }
  const config = getIlseongConfig();
  const notify = makeNotifier({ baseUrl: selfBaseUrl(req), cronSecret });

  // 1) 크론
  if (cronSecret && token === cronSecret) {
    if (req.method !== "GET") {
      return res.status(405).json(makeErrorResponse("Method not allowed", "METHOD_NOT_ALLOWED"));
    }
    try {
      const result = await runQueue({ service, config, notify });
      return res.status(200).json({ success: true, ...result });
    } catch (err) {
      console.error("ilseong-app-codes cron error:", err);
      return res.status(500).json(makeErrorResponse(err?.message || "Internal error", "CRON_FAILED"));
    }
  }

  // 2) 관리자
  if (!token) {
    return res.status(401).json(makeErrorResponse("Missing auth token", "MISSING_AUTH_TOKEN"));
  }
  let admin;
  try {
    admin = await assertAdmin(token);
  } catch (err) {
    return res.status(err.statusCode || 500).json(makeErrorResponse(err.message, err.message));
  }

  let action;
  let body = {};
  if (req.method === "GET") {
    action = String(req.query?.action || "overview");
  } else if (req.method === "POST") {
    body = req.body && typeof req.body === "object" ? req.body : {};
    action = String(body.action || "");
  } else {
    res.setHeader("Allow", "GET, POST");
    return res.status(405).json(makeErrorResponse("Method not allowed", "METHOD_NOT_ALLOWED"));
  }
  if (req.method === "GET" && action !== "overview") {
    return res.status(405).json(makeErrorResponse("GET은 overview만 지원합니다.", "METHOD_NOT_ALLOWED"));
  }

  try {
    const result = await handleAdminAction({ action, body, service, config, notify, userId: admin.userId });
    return res.status(200).json({ success: true, ...result });
  } catch (err) {
    const status = err.statusCode || (err instanceof IlseongApiError ? 502 : 500);
    return res.status(status).json(makeErrorResponse(err.message, err.code || "ILSEONG_APP_ERROR"));
  }
}
