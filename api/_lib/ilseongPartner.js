import { createHash, createHmac } from "node:crypto";

// 일성월심 앱 서버 판매처(partner) API 클라이언트.
// 서명: hex(HMAC-SHA256(비밀값, "subook\n" + 시각 + "\n" + 메서드 + "\n" + 경로 + "\n" + hex(SHA-256(본문 바이트)))).
// 경로는 쿼리 없는 경로. 서명한 바이트와 보낸 본문이 정확히 같아야 하므로 본문은 Buffer로 한 번만 만든다.
// 앱 서버 문서: ilseong-app docs/adr/0004-partner-order-codes.md

export const ILSEONG_PARTNER = "subook";
export const ILSEONG_DEFAULT_PRODUCT_CODE = "ILSEONG_2028_SET4";
export const ILSEONG_MAX_LINES_PER_REQUEST = 20;

const REF_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;
const DEFAULT_TIMEOUT_MS = 6_000;

// 두 환경 변수가 모두 있어야 켜진다. 하나라도 없으면 앱 서버를 부르지 않는다.
export function getIlseongConfig(env = process.env) {
  const baseUrl = String(env.ILSEONG_API_BASE_URL || "").trim().replace(/\/+$/, "");
  const secret = String(env.ILSEONG_PARTNER_SECRET || "");
  const validUrl = /^https?:\/\/[^\s/]+/i.test(baseUrl);
  return { configured: Boolean(validUrl && secret.trim()), baseUrl, secret };
}

export function isValidRef(value) {
  return typeof value === "string" && REF_PATTERN.test(value);
}

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes ?? Buffer.alloc(0)).digest("hex");
}

export function signPartnerRequest({ secret, partner = ILSEONG_PARTNER, timestamp, method, path, body }) {
  const bodyBytes = body == null ? Buffer.alloc(0) : Buffer.isBuffer(body) ? body : Buffer.from(String(body), "utf8");
  const payload = `${partner}\n${timestamp}\n${String(method).toUpperCase()}\n${path}\n${sha256Hex(bodyBytes)}`;
  return createHmac("sha256", Buffer.from(String(secret), "utf8")).update(payload, "utf8").digest("hex");
}

export class IlseongApiError extends Error {
  constructor(message, { status = 0, code = "NETWORK_ERROR", retryable = true } = {}) {
    super(message);
    this.name = "IlseongApiError";
    this.status = status;
    this.code = code;
    this.retryable = retryable;
  }
}

function assertRef(value, label) {
  if (!isValidRef(value)) {
    throw new IlseongApiError(`${label} 형식이 올바르지 않습니다: ${value}`, { status: 0, code: "INVALID_REF", retryable: false });
  }
}

export function createIlseongClient({
  baseUrl,
  secret,
  partner = ILSEONG_PARTNER,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  timeoutMs = DEFAULT_TIMEOUT_MS,
} = {}) {
  if (!baseUrl || !secret) {
    throw new Error("ILSEONG_API_BASE_URL / ILSEONG_PARTNER_SECRET 미설정");
  }

  async function call(method, pathname, payload) {
    const url = new URL(pathname, `${baseUrl}/`);
    const path = url.pathname;
    const body = payload === undefined ? null : Buffer.from(JSON.stringify(payload), "utf8");
    const timestamp = String(Math.floor(now() / 1000));
    const headers = {
      Accept: "application/json",
      "X-Ilseong-Partner": partner,
      "X-Ilseong-Timestamp": timestamp,
      "X-Ilseong-Signature": signPartnerRequest({ secret, partner, timestamp, method, path, body }),
    };
    if (body) headers["Content-Type"] = "application/json";

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let response;
    try {
      response = await fetchImpl(url.toString(), { method, headers, body: body ?? undefined, signal: controller.signal });
    } catch (err) {
      const timedOut = err?.name === "AbortError";
      throw new IlseongApiError(timedOut ? `앱 서버 응답 시간 초과 (${timeoutMs}ms)` : `앱 서버 연결 실패: ${err?.message || err}`, {
        code: timedOut ? "TIMEOUT" : "NETWORK_ERROR",
      });
    } finally {
      clearTimeout(timer);
    }

    const text = await response.text().catch(() => "");
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = null;
    }
    if (!response.ok) {
      const code = data?.code || `HTTP_${response.status}`;
      // 4xx는 같은 요청을 다시 보내도 같은 결과(서명 오류 401은 시계·비밀값 문제라 재시도 대상으로 둔다)
      const retryable = response.status >= 500 || response.status === 401 || response.status === 429;
      throw new IlseongApiError(`앱 서버 오류 ${response.status} ${code}: ${data?.detail || data?.title || text.slice(0, 200)}`, {
        status: response.status,
        code,
        retryable,
      });
    }
    return data;
  }

  const orderPath = (orderRef) => `/api/partner/orders/${orderRef}`;

  return {
    // 같은 주문 줄은 몇 번을 보내도 같은 코드
    async issueCodes(orderRef, lines) {
      assertRef(orderRef, "orderRef");
      if (!Array.isArray(lines) || lines.length < 1 || lines.length > ILSEONG_MAX_LINES_PER_REQUEST) {
        throw new IlseongApiError("주문 줄은 1–20개여야 합니다.", { code: "INVALID_LINES", retryable: false });
      }
      for (const line of lines) assertRef(line.lineRef, "lineRef");
      return call("POST", `${orderPath(orderRef)}/codes`, {
        lines: lines.map((line) => ({ lineRef: line.lineRef, productCode: line.productCode })),
      });
    },
    async getOrder(orderRef) {
      assertRef(orderRef, "orderRef");
      return call("GET", orderPath(orderRef));
    },
    async revoke(orderRef, { lineRefs, revokeAccess }) {
      assertRef(orderRef, "orderRef");
      const payload = { revokeAccess: Boolean(revokeAccess) };
      if (Array.isArray(lineRefs) && lineRefs.length > 0) {
        lineRefs.forEach((ref) => assertRef(ref, "lineRef"));
        payload.lineRefs = lineRefs;
      }
      return call("POST", `${orderPath(orderRef)}/revoke`, payload);
    },
    async reissue(orderRef, lineRef) {
      assertRef(orderRef, "orderRef");
      assertRef(lineRef, "lineRef");
      return call("POST", `${orderPath(orderRef)}/lines/${lineRef}/reissue`);
    },
  };
}

export function chunk(list, size = ILSEONG_MAX_LINES_PER_REQUEST) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

// 관리 화면에는 코드 원문을 보내지 않는다: 앞 4자·뒤 4자만
export function maskAppCode(code) {
  const value = String(code || "");
  if (!value) return null;
  const groups = value.split("-");
  if (groups.length === 4) return `${groups[0]}-••••-••••-${groups[3]}`;
  return value.length <= 8 ? "••••" : `${value.slice(0, 4)}…${value.slice(-4)}`;
}

// ── 주문 한 건 맞추기 ─────────────────────────────────────────
// 줄 상태를 보고 발급 → 폐기 → 알림 순서로 처리한다. 각 단계는 다시 해도 같은 결과(멱등).
// deps: { client, rpc(name, args) → data, notify({ order, lines, allowDuplicate }) → { ok, error } }
export async function syncOrder({ context, client, rpc, notify }) {
  const order = context?.order;
  const lines = Array.isArray(context?.lines) ? context.lines : [];
  if (!order?.id || !order.order_number) {
    return { ok: true, skipped: "order_missing" };
  }
  const orderRef = order.order_number;
  const result = { issued: 0, revoked: 0, notified: 0 };

  // 1) 발급
  const toIssue = lines.filter((line) => line.status === "pending" && !line.revoke_requested_at);
  if (toIssue.length > 0) {
    if (order.payment_status !== "paid") {
      throw new IlseongApiError(`결제 확인 전 주문입니다 (${order.payment_status})`, { code: "NOT_PAID", retryable: true });
    }
    for (const part of chunk(toIssue)) {
      const response = await client.issueCodes(orderRef, part.map((line) => ({
        lineRef: line.line_ref,
        productCode: line.app_product_code,
      })));
      await rpc("ilseong_app_record_lines", { p_order_id: order.id, p_lines: response?.lines ?? [], p_reissued: false });
      result.issued += Array.isArray(response?.lines) ? response.lines.length : 0;
    }
  }

  // 2) 환불 폐기 — 앱 서버에 있는 줄만 보낸다(발급 전이었던 줄은 폐기로 기록)
  const toRevoke = lines.filter((line) => line.revoke_requested_at && !line.revoke_processed_at);
  if (toRevoke.length > 0) {
    let remote = [];
    try {
      const status = await client.getOrder(orderRef);
      remote = Array.isArray(status?.lines) ? status.lines : [];
    } catch (err) {
      if (!(err instanceof IlseongApiError && err.code === "ORDER_NOT_FOUND")) throw err;
    }
    const remoteRefs = new Set(remote.map((line) => line.lineRef));
    const missing = toRevoke.filter((line) => !remoteRefs.has(line.line_ref)).map((line) => line.line_ref);
    if (missing.length > 0) {
      await rpc("ilseong_app_mark_revoke_processed", { p_order_id: order.id, p_line_refs: missing });
    }
    for (const revokeAccess of [true, false]) {
      const refs = toRevoke
        .filter((line) => remoteRefs.has(line.line_ref) && Boolean(line.revoke_access) === revokeAccess)
        .map((line) => line.line_ref);
      for (const part of chunk(refs)) {
        const response = await client.revoke(orderRef, { lineRefs: part, revokeAccess });
        await rpc("ilseong_app_record_lines", { p_order_id: order.id, p_lines: response?.lines ?? [], p_reissued: false });
        await rpc("ilseong_app_mark_revoke_processed", { p_order_id: order.id, p_line_refs: part });
        result.revoked += part.length;
      }
    }
  }

  // 3) 알림톡 — 새로 받은 코드를 다시 읽어 보낸다
  const fresh = (toIssue.length > 0 || toRevoke.length > 0)
    ? await rpc("ilseong_app_order_context", { p_order_id: order.id })
    : context;
  const freshLines = Array.isArray(fresh?.lines) ? fresh.lines : [];
  const toNotify = freshLines.filter((line) =>
    line.code && ["issued", "redeemed"].includes(line.status) && !line.notified_at && !line.revoke_requested_at);
  if (toNotify.length > 0) {
    const sent = await notify({
      order: fresh.order ?? order,
      settings: fresh.settings ?? context.settings,
      lines: toNotify,
      // 재발급한 코드는 이미 보낸 알림과 멱등 키가 같으므로 중복 허용으로 보낸다
      allowDuplicate: toNotify.some((line) => line.reissued_at),
    });
    if (!sent?.ok) {
      throw new IlseongApiError(`알림톡 발송 실패: ${sent?.error || "알 수 없는 오류"}`, { code: "NOTIFY_FAILED" });
    }
    await rpc("ilseong_app_mark_notified", { p_order_id: order.id, p_line_refs: toNotify.map((line) => line.line_ref) });
    result.notified += toNotify.length;
  }

  return { ok: true, ...result };
}
