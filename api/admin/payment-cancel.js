import { createClient } from "@supabase/supabase-js";

// 관리자 환불 — 품목별 부분환불 지원 (2026-08-01) + PG 프로바이더(나이스페이/토스) 분기.
//
// 신규 흐름 (itemIds 포함 요청 — 어드민 환불 모달):
//   1) admin_refund_order_items(p_validate_only=true)로 DB 검증만 먼저 수행.
//      RECOVERY_REQUIRED_ACK(송금 완료 정산)·금액 초과·품목 오류를 PG 취소 **전에** 걸러낸다.
//      → 손실확인 재시도 플로우에서 PG가 이중취소될 여지를 구조적으로 제거.
//   2) PG 주문이면 프로바이더별 (부분)취소:
//      · 나이스페이: POST /v1/payments/{tid}/cancel, cancelAmt=금액.
//        ⚠ 부분취소는 동일 orderId 재호출이 거부되므로 취소 orderId를
//          `${order_number}-R${환불누계}`로 만든다 — 같은 논리적 환불의 재시도는 같은 orderId가
//          되어 나이스페이가 중복을 거부(=이중취소 방지), 다음 환불 건은 누계가 달라져 통과.
//        ⚠ 취소 실패 시 거래조회(GET /v1/payments/{tid})로 '이미 전액취소된 결제'인지 확인 —
//          나이스페이 콘솔에서 직접 취소한 주문(2026-08-04 ORD-2608-0077 사례)도 어드민에서
//          DB 환불(재고 롤백)을 마저 진행할 수 있게 멱등 성공 처리한다. 단 이 경우 돈은 이미
//          전액 돌아간 상태이므로 "남은 금액 전액 환불" 요청일 때만 허용(부분 기록 어긋남 방지).
//      · 토스: POST /v1/payments/{paymentKey}/cancel, cancelAmount=금액 + 결정적 Idempotency-Key.
//        이미 전액취소된 결제(ALREADY_CANCELED_PAYMENT)도 같은 전액-요청 게이트를 거쳐 멱등 성공.
//   3) admin_refund_order_items(p_validate_only=false)로 DB 확정 (품목 스탬프·정산·재고·쿠폰·누계).
//      이 단계 실패는 동시 조작 등 희귀 케이스 — PG 취소는 이미 성공했으므로 CRITICAL로 응답한다.
//
// 레거시 흐름 (itemIds 없는 요청 — 배포 전 열려 있던 구버전 어드민 탭):
//   기존과 동일하게 토스 전액취소 → admin_refund_order. 나이스페이 주문은 구버전 화면에서
//   처리 불가(새로고침 안내) — 이전에는 나이스페이 TID를 토스 API로 보내는 버그가 있었다.
//
// 계좌이체 주문(payment_key 없음)은 PG 단계를 건너뛰고 DB 환불만 (운영자가 수동 송금).

const TOSS_CANCEL_BASE = "https://api.tosspayments.com/v1/payments";
const NICEPAY_PROD_API_BASE = "https://api.nicepay.co.kr";
const NICEPAY_SANDBOX_API_BASE = "https://sandbox-api.nicepay.co.kr";
const PG_TIMEOUT_MS = 10_000;

function getSupabaseConfig() {
  const url = process.env.SUPABASE_ADMIN_URL || process.env.VITE_SUPABASE_ADMIN_URL;
  const anonKey = process.env.SUPABASE_ADMIN_ANON_KEY || process.env.VITE_SUPABASE_ADMIN_ANON_KEY;
  return { url, anonKey };
}

function getNicepayConfig() {
  const clientKey = process.env.NICEPAY_CLIENT_KEY || "";
  const secretKey = process.env.NICEPAY_SECRET_KEY || "";
  // 샌드박스 키(S2_ 접두사)면 샌드박스 API로 자동 라우팅 (nicepay-return.js와 동일 규칙)
  const apiBase =
    process.env.NICEPAY_API_BASE ||
    (clientKey.startsWith("S2_") ? NICEPAY_SANDBOX_API_BASE : NICEPAY_PROD_API_BASE);
  return { clientKey, secretKey, apiBase };
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

async function fetchWithTimeout(url, options, timeoutMs = PG_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

// 토스 결제 취소. cancelAmount 없으면 잔액 전액취소.
// 결정적 Idempotency-Key로 같은 논리적 취소의 재시도는 이전 응답이 재생돼 이중취소가 안 된다.
async function cancelTossPayment({ paymentKey, reason, cancelAmount, idempotencyKey }) {
  const secretKey = process.env.TOSS_SECRET_KEY;
  if (!secretKey) {
    return { ok: false, code: "TOSS_CONFIG_MISSING", message: "결제 취소 설정이 누락되었습니다." };
  }
  try {
    const auth = "Basic " + Buffer.from(`${secretKey}:`).toString("base64");
    const body = { cancelReason: (reason && String(reason).slice(0, 200)) || "관리자 환불" };
    if (Number.isInteger(cancelAmount) && cancelAmount > 0) body.cancelAmount = cancelAmount;
    const resp = await fetchWithTimeout(`${TOSS_CANCEL_BASE}/${encodeURIComponent(paymentKey)}/cancel`, {
      method: "POST",
      headers: {
        Authorization: auth,
        "Content-Type": "application/json",
        "Idempotency-Key": idempotencyKey || `subook-cancel-${paymentKey}`,
      },
      body: JSON.stringify(body),
    });
    const respBody = await resp.json();
    if (resp.ok) return { ok: true, body: respBody };
    // 이미 전액 취소된 결제 → 멱등 성공 (돈은 이미 돌아간 상태 — DB만 맞추면 됨)
    if (respBody?.code === "ALREADY_CANCELED_PAYMENT") return { ok: true, body: respBody, alreadyCanceled: true };
    return { ok: false, code: respBody?.code || "TOSS_CANCEL_FAILED", message: respBody?.message || "결제 취소에 실패했습니다." };
  } catch (err) {
    return {
      ok: false,
      code: "TOSS_CANCEL_ERROR",
      message: err?.name === "AbortError" ? "결제 취소 응답이 지연되었습니다." : "결제 취소 중 오류가 발생했습니다.",
    };
  }
}

// 나이스페이 거래 조회 — GET /v1/payments/{tid}. 취소 실패가 '이미 취소된 결제' 때문인지 판별용.
// status: paid/ready/failed/cancelled(전액취소)/partialCancelled/expired, balanceAmt: 취소 가능 잔액.
// 파싱된 응답을 그대로 반환한다(resultCode 판정은 호출부) — 실패 진단 로그에 원본이 필요.
async function getNicepayPayment(tid) {
  const { clientKey, secretKey, apiBase } = getNicepayConfig();
  try {
    const auth = "Basic " + Buffer.from(`${clientKey}:${secretKey}`).toString("base64");
    const resp = await fetchWithTimeout(`${apiBase}/v1/payments/${encodeURIComponent(tid)}`, {
      headers: { Authorization: auth },
    });
    return await resp.json().catch(() => null);
  } catch {
    return null;
  }
}

// 나이스페이 결제 취소 — POST /v1/payments/{tid}/cancel (Basic clientKey:secretKey).
// cancelAmt 없으면 전액취소. 부분취소는 취소 요청별 고유 orderId 필수(중복 거부).
// ⚠ U112(이미 사용된 OrderId): 취소가 실패해도 나이스페이는 orderId를 등록해 둔다 —
//   과거 실패한 시도가 결정적 orderId(-R누계)를 소진하면 재시도가 영구히 U112로 막힌다
//   (2026-08-19 ORD-2608-0147 실사례). 이 경우 거래조회로 "잔액 == 이번 취소액"
//   (= 남은 전액 취소, 돈이 아직 그대로)을 확인한 때에 한해 새 orderId로 1회 재시도한다.
//   잔액 전액 취소만 재시도하므로 이중취소는 구조적으로 불가능 — 경쟁 취소가 먼저
//   성공하면 잔액이 0이 되어 이쪽 요청은 U123/2032(취소가능금액 초과)로 거부된다.
// ⚠ 2033(부분취소 불가능금액): cancelAmt를 담으면 금액이 전액이어도 '부분취소'로
//   라우팅되고, 매입 전(당일) 거래는 카드사가 부분취소를 거부한다(같은 실사례 —
//   이 2033 거부가 orderId를 소진해 위 U112 상태를 만든 원흉).
//   → 이번 취소로 잔액이 0이 되는 요청(fullCancel)은 cancelAmt 없이 전액취소 폼으로
//   보낸다. 전액취소 전 거래조회로 "나이스페이 잔액 == 취소 예정액"을 확인해
//   DB 드리프트(콘솔 부분취소 등)로 장부가 어긋나는 것을 막는다.
async function cancelNicepayPayment({ tid, reason, cancelOrderId, cancelAmt, fullCancel = false, isRetry = false }) {
  const { clientKey, secretKey, apiBase } = getNicepayConfig();
  if (!clientKey || !secretKey) {
    return {
      ok: false,
      code: "NICEPAY_CONFIG_MISSING",
      message: "나이스페이 취소 설정(NICEPAY_CLIENT_KEY/SECRET_KEY)이 admin 서버에 없습니다. Vercel 환경 변수를 확인해주세요.",
    };
  }
  try {
    // 전액취소 사전 검증 — 잔액이 취소 예정액과 다르면 진행하지 않는다 (재시도 호출은
    // U112 게이트에서 이미 검증됨). 조회 자체가 실패하면 취소 시도로 진행 — 취소 API의
    // 자체 잔액 검증이 최종 방어선이고, 조회 실패로 환불 전체를 막는 게 더 큰 손해.
    if (fullCancel && !isRetry) {
      const pre = await getNicepayPayment(tid);
      if (pre?.resultCode === "0000") {
        const preBalance = Number(pre?.balanceAmt ?? -1);
        if (pre?.status === "cancelled" && preBalance === 0) {
          return { ok: true, body: pre, alreadyCanceled: true };
        }
        if (preBalance !== cancelAmt) {
          console.error("[payment-cancel] nicepay 전액취소 사전검증 실패 — 잔액 불일치", {
            tid,
            cancelAmt,
            preStatus: pre?.status ?? null,
            preBalanceAmt: pre?.balanceAmt ?? null,
          });
          return {
            ok: false,
            code: "NICEPAY_BALANCE_MISMATCH",
            message:
              `나이스페이 취소 가능 잔액(${preBalance.toLocaleString("ko-KR")}원)이 환불 요청 금액` +
              `(${Number(cancelAmt ?? 0).toLocaleString("ko-KR")}원)과 다릅니다. ` +
              `나이스페이 가맹점 콘솔에서 취소 내역을 확인해주세요.`,
          };
        }
      }
    }
    const auth = "Basic " + Buffer.from(`${clientKey}:${secretKey}`).toString("base64");
    const body = {
      reason: (reason && String(reason).slice(0, 100)) || "관리자 환불",
      orderId: cancelOrderId,
    };
    // 부분취소일 때만 cancelAmt 포함 — 전액취소는 cancelAmt 생략이 규격(있으면 2033 위험)
    if (!fullCancel && Number.isInteger(cancelAmt) && cancelAmt > 0) body.cancelAmt = cancelAmt;
    const resp = await fetchWithTimeout(`${apiBase}/v1/payments/${encodeURIComponent(tid)}/cancel`, {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/json;charset=utf-8" },
      body: JSON.stringify(body),
    });
    const respBody = await resp.json().catch(() => null);
    if (respBody?.resultCode === "0000") return { ok: true, body: respBody };
    // 취소 실패 — 나이스페이 콘솔에서 이미 전액취소된 결제인지 거래조회로 판별.
    // ('이미 취소됨' 전용 resultCode가 규격에 없어 상태 조회로 확인. 전액취소(cancelled·잔액 0)
    //  확인 시 멱등 성공 — 돈은 이미 돌아갔으므로 DB만 맞추면 된다. 토스와 동일 정책)
    const inquiry = await getNicepayPayment(tid);
    const inquiryOk = inquiry?.resultCode === "0000";
    if (inquiryOk && inquiry?.status === "cancelled" && Number(inquiry?.balanceAmt ?? 0) === 0) {
      return { ok: true, body: inquiry, alreadyCanceled: true };
    }
    // U112(orderId 소진) + 결제가 아직 그대로(잔액 == 이번 취소액)면 새 orderId로 1회 재시도.
    // 잔액과 취소액이 다르면(이미 일부 취소됨 등) 자동 재시도하지 않는다 — 금액 어긋남 방지.
    if (
      !isRetry &&
      respBody?.resultCode === "U112" &&
      inquiryOk &&
      Number.isInteger(cancelAmt) &&
      cancelAmt > 0 &&
      Number(inquiry?.balanceAmt ?? -1) === cancelAmt &&
      (inquiry?.status === "paid" || inquiry?.status === "partialCancelled")
    ) {
      const retryOrderId = `${cancelOrderId}-T${Date.now()}`;
      console.warn("[payment-cancel] U112 orderId 소진 감지 — 새 orderId로 재시도", {
        tid,
        cancelOrderId,
        retryOrderId,
        cancelAmt,
        inquiryStatus: inquiry?.status ?? null,
        inquiryBalanceAmt: inquiry?.balanceAmt ?? null,
      });
      return cancelNicepayPayment({ tid, reason, cancelOrderId: retryOrderId, cancelAmt, fullCancel, isRetry: true });
    }
    // 여기 도달 = 진짜 실패. 운영 진단용 로그 (취소 응답 + 거래조회 결과 원본)
    console.error("[payment-cancel] nicepay cancel failed", {
      tid,
      cancelOrderId,
      cancelAmt,
      cancelHttp: resp.status,
      cancelResultCode: respBody?.resultCode ?? null,
      cancelResultMsg: respBody?.resultMsg ?? null,
      inquiryResultCode: inquiry?.resultCode ?? null,
      inquiryStatus: inquiry?.status ?? null,
      inquiryBalanceAmt: inquiry?.balanceAmt ?? null,
    });
    if (inquiryOk && inquiry?.status === "partialCancelled") {
      return {
        ok: false,
        code: respBody?.resultCode || "NICEPAY_CANCEL_FAILED",
        message:
          `결제 취소에 실패했습니다: ${respBody?.resultMsg || "사유 미상"} — 나이스페이 조회 결과 ` +
          `부분취소 상태(취소 가능 잔액 ${Number(inquiry.balanceAmt ?? 0).toLocaleString("ko-KR")}원)입니다. ` +
          `나이스페이 가맹점 콘솔에서 취소 내역을 확인해주세요.`,
      };
    }
    if (respBody?.resultCode === "U112" && inquiryOk) {
      return {
        ok: false,
        code: "U112",
        message:
          `결제 취소에 실패했습니다: ${respBody?.resultMsg || "이미 사용된 OrderId"} — 취소 가능 잔액 ` +
          `${Number(inquiry?.balanceAmt ?? 0).toLocaleString("ko-KR")}원이 요청 금액 ` +
          `${Number(cancelAmt ?? 0).toLocaleString("ko-KR")}원과 달라 자동 재시도하지 않았습니다. ` +
          `나이스페이 가맹점 콘솔에서 취소 내역을 확인해주세요.`,
      };
    }
    return {
      ok: false,
      code: respBody?.resultCode || "NICEPAY_CANCEL_FAILED",
      message: respBody?.resultMsg || `결제 취소에 실패했습니다. (http ${resp.status})`,
    };
  } catch (err) {
    return {
      ok: false,
      code: "NICEPAY_CANCEL_ERROR",
      message: err?.name === "AbortError" ? "결제 취소 응답이 지연되었습니다." : "결제 취소 중 오류가 발생했습니다.",
    };
  }
}

// 프로바이더 공통 진입점 — pg_provider('nicepay'|'toss', 레거시 null=toss)로 분기
async function cancelPgPayment({ order, reason, amount, itemIds }) {
  const provider = order.pg_provider || "toss";
  const refundedBefore = Number(order.refunded_amount ?? 0);

  if (provider === "nicepay") {
    return cancelNicepayPayment({
      tid: order.payment_key,
      reason,
      // 취소 요청별 고유 + 재시도엔 결정적: 환불 누계(이번 포함)를 접미사로 사용
      cancelOrderId: `${order.order_number}-R${refundedBefore + amount}`,
      cancelAmt: amount,
      // 이번 취소로 주문 잔액이 0 → 전액취소 폼(cancelAmt 생략). 매입 전 거래는
      // 부분취소가 카드사에서 거부(2033)되므로 전액 환불을 부분취소로 보내면 안 된다.
      fullCancel: refundedBefore + amount === Number(order.total_amount ?? 0),
    });
  }

  const sortedIds = [...(itemIds || [])].map(Number).sort((a, b) => a - b);
  return cancelTossPayment({
    paymentKey: order.payment_key,
    reason,
    cancelAmount: amount,
    idempotencyKey: `subook-cancel-${order.payment_key}-${refundedBefore}-${amount}-${sortedIds.join("_")}`,
  });
}

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

  const { orderId, reason, acknowledgeRecovery, itemIds, refundAmount } = req.body || {};
  if (!orderId) {
    return res.status(400).json(makeErrorResponse({ error: "orderId is required", code: "MISSING_ORDER_ID" }));
  }

  // 주문 조회 — 결제수단/프로바이더/환불 누계 확인 (admin RLS로 조회 가능)
  const { data: order, error: orderErr } = await supabase
    .from("orders")
    .select("id, order_number, status, payment_method, payment_key, pg_provider, total_amount, refunded_amount")
    .eq("id", orderId)
    .single();
  if (orderErr || !order) {
    return res.status(404).json(makeErrorResponse({ error: "주문을 찾을 수 없습니다.", code: "ORDER_NOT_FOUND" }));
  }

  const hasItemSelection = Array.isArray(itemIds) && itemIds.length > 0;

  // ── 신규 흐름: 품목 선택 환불 (부분/전액 공용) ───────────────────────────────
  if (hasItemSelection) {
    const rpcParams = {
      p_order_id: orderId,
      p_order_item_ids: itemIds.map(Number),
      p_refund_amount: Number.isInteger(refundAmount) && refundAmount > 0 ? refundAmount : null,
      p_reason: reason ?? null,
      p_acknowledge_recovery: Boolean(acknowledgeRecovery),
    };

    // 1) DB 검증만 먼저 — PG 취소 전에 모든 거부 사유(RECOVERY_REQUIRED_ACK 포함)를 걸러낸다
    const validate = await supabase.rpc("admin_refund_order_items", { ...rpcParams, p_validate_only: true });
    if (validate.error) {
      return res.status(409).json(makeErrorResponse({ error: validate.error.message, code: "REFUND_RPC_ERROR" }));
    }
    const amount = Number(validate.data?.refund_amount ?? 0);
    if (!Number.isInteger(amount) || amount <= 0) {
      return res.status(409).json(makeErrorResponse({ error: "환불 금액 계산에 실패했습니다.", code: "REFUND_AMOUNT_INVALID" }));
    }

    // 2) PG 주문이면 (부분)취소. 계좌이체(payment_key 없음)는 건너뜀.
    let pgCancelled = false;
    let pgAlreadyCancelled = false;
    if (order.payment_key) {
      const cancelRes = await cancelPgPayment({ order, reason, amount, itemIds });
      if (!cancelRes.ok) {
        // PG 취소 실패 → DB는 건드리지 않고 종료 (구매자 불리 상태 방지)
        return res.status(502).json(makeErrorResponse({ error: cancelRes.message, code: cancelRes.code }));
      }
      // PG가 "이미 전액취소된 결제"라고 알려준 경우(나이스페이 콘솔 직접취소 등) —
      // 돈은 이미 전부 돌아간 상태다. DB를 부분환불로 기록하면 실제 환불액과 어긋나므로
      // "남은 금액 전액 환불" 요청일 때만 DB 확정으로 진행한다.
      if (cancelRes.alreadyCanceled) {
        const remaining = Number(validate.data?.remaining_refundable ?? 0);
        const isFullRemaining = validate.data?.order_fully_refunded === true && amount === remaining;
        if (!isFullRemaining) {
          return res.status(409).json(
            makeErrorResponse({
              error:
                "PG에서 이미 전액취소된 결제입니다. 부분 금액으로 기록하면 실제 환불된 금액과 어긋나므로, " +
                "남은 품목을 모두 선택하고 금액을 기본값(남은 전액)으로 두고 환불 처리해주세요.",
              code: "PG_ALREADY_CANCELLED_FULL_ONLY",
            }),
          );
        }
        pgAlreadyCancelled = true;
      }
      pgCancelled = true;
    }

    // 3) DB 확정 — 검증을 이미 통과했으므로 실패는 동시 조작 등 희귀 케이스.
    //    PG 취소는 성공한 상태라 절대 조용히 삼키지 않는다.
    const commit = await supabase.rpc("admin_refund_order_items", { ...rpcParams, p_validate_only: false });
    if (commit.error) {
      console.error("[payment-cancel] CRITICAL: PG 취소 성공 후 DB 확정 실패", {
        orderId,
        orderNumber: order.order_number,
        amount,
        pgCancelled,
        error: commit.error.message,
      });
      // 운영 슬랙 즉시 경보 — PG 취소 성공·DB 미반영(돈-장부 불일치)은 방치되면 안 됨
      try {
        await supabase.rpc("notify_ops_slack", {
          p_text: `:rotating_light: 환불 CRITICAL: PG 취소 성공 후 DB 확정 실패\n주문 ${order.order_number} · ${amount.toLocaleString("ko-KR")}원 · ${commit.error.message}`,
        });
      } catch {
        // 경보 실패는 무시 — 응답 흐름을 막지 않는다
      }
      return res.status(500).json(
        makeErrorResponse({
          error: pgCancelled
            ? `⚠ PG 결제취소(${amount.toLocaleString("ko-KR")}원)는 성공했으나 DB 반영에 실패했습니다: ${commit.error.message} — 새로고침 후 주문 상태를 확인하고, 품목 환불 표시가 없으면 개발자에게 문의하세요. (같은 요청 재시도 시 PG 중복취소는 자동 차단됩니다)`
            : commit.error.message,
          code: "REFUND_COMMIT_FAILED",
        }),
      );
    }

    return res.status(200).json({
      success: true,
      data: commit.data,
      pg_cancelled: pgCancelled,
      pg_already_cancelled: pgAlreadyCancelled,
    });
  }

  // ── 레거시 흐름: 주문 전체 환불 (배포 전 구버전 어드민 탭 호환) ────────────────
  // 나이스페이 주문은 구버전 화면에서 처리 불가 — 새 화면(품목 선택 모달)으로 유도.
  if (order.payment_key && (order.pg_provider || "toss") === "nicepay") {
    // 구버전 어드민 탭(품목 선택 모달 이전)에서 나이스페이 주문 환불 시도 — 진단용 로그
    console.error("[payment-cancel] legacy flow blocked for nicepay order", {
      orderNumber: order.order_number,
    });
    return res.status(400).json(
      makeErrorResponse({
        error: "나이스페이 주문은 새 환불 화면에서 처리해주세요. 관리자 화면을 새로고침하면 품목 선택 환불 모달이 열립니다.",
        code: "NICEPAY_REQUIRES_NEW_CLIENT",
      }),
    );
  }

  // 1) 토스 주문이면 결제 취소 먼저 (전액, 기존 멱등키 유지). 계좌이체는 건너뜀.
  let pgCancelled = false;
  if (order.payment_key) {
    const cancelRes = await cancelTossPayment({ paymentKey: order.payment_key, reason });
    if (!cancelRes.ok) {
      return res.status(502).json(makeErrorResponse({ error: cancelRes.message, code: cancelRes.code }));
    }
    pgCancelled = true;
  }

  // 2) DB 환불 (정산 취소/회수 표시 · reserved 재고 복원 · 쿠폰 복구). admin 권한으로 호출.
  const { data, error } = await supabase.rpc("admin_refund_order", {
    p_order_id: orderId,
    p_reason: reason ?? null,
    p_acknowledge_recovery: Boolean(acknowledgeRecovery),
  });
  if (error) {
    // RECOVERY_REQUIRED_ACK 등은 메시지를 그대로 전달 → 프론트가 손실확인 모달로 분기.
    // (이 시점 토스 취소는 이미 됐고 멱등이라, 손실확인 후 재호출해도 안전)
    return res.status(409).json(makeErrorResponse({ error: error.message, code: "REFUND_RPC_ERROR" }));
  }

  return res.status(200).json({ success: true, data, pg_cancelled: pgCancelled });
}
