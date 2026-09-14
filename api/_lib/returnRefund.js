// 입력 금액을 신뢰하지 않는다. 승인된 반품의 서버 스냅샷으로만 PG와 장부를 처리한다.
export function matchesReturnRefund(attempt, payment) {
  if (!payment || payment.total !== Number(attempt.order.total_amount)
    || payment.balance !== attempt.remaining_before - attempt.refund_amount) return false;
  if (payment.balance === 0 && attempt.refund_amount === attempt.remaining_before && attempt.whole_order) return true;
  const startedAt = Date.parse(attempt.claimed_at);
  return Number.isFinite(startedAt) && (payment.cancels ?? []).some(cancel =>
    cancel.amount === attempt.refund_amount && Date.parse(cancel.at) >= startedAt - 5000 && cancel.done !== false);
}

export async function processReturnRefund({ supabase, returnId, action = "execute", transferReference, acknowledgeRecovery, cancelPayment, getPayment }) {
  if (!["execute", "reconcile"].includes(action)) return { status: 400, body: { error: "지원하지 않는 환불 작업입니다.", code: 400, reasonCode: "INVALID_ACTION" } };
  const start = await supabase.rpc(action === "reconcile" ? "admin_get_return_refund_attempt" : "admin_claim_return_refund",
    action === "reconcile" ? { p_return_id: returnId } : {
      p_return_id: returnId, p_transfer_reference: transferReference || null, p_acknowledge_recovery: acknowledgeRecovery === true,
    });
  if (start.error) return { status: 409, body: { error: start.error.message, code: 409, reasonCode: "RETURN_NOT_READY" } };
  const attempt = start.data;
  const flag = async (message) => {
    try {
      await supabase.rpc("admin_flag_return_refund", { p_return_id: returnId, p_token: attempt.token, p_note: message });
      await supabase.rpc("notify_ops_slack", { p_text: `반품 환불 확인 필요: 주문 ${attempt.order.order_number} · ${attempt.refund_amount}원 · ${message}` });
    } catch { /* 최초 실패 메시지를 유지한다. */ }
    return { status: 409, body: { error: message, code: 409, reasonCode: "RETURN_REFUND_ATTENTION" } };
  };
  try {
    const { order, item_ids: itemIds, refund_amount: amount, reason } = attempt;
    if (order.payment_key) {
      const before = await getPayment(order);
      if (action === "reconcile") {
        if (!matchesReturnRefund(attempt, before)) {
          return await flag("PG 거래내역에서 승인된 금액의 환불 완료를 확인하지 못했습니다. 재취소하지 않았습니다. PG 취소내역과 금액을 확인해주세요.");
        }
      } else if (!matchesReturnRefund(attempt, before)) {
        if (!before || before.balance !== attempt.remaining_before || before.total !== Number(order.total_amount)) {
          return await flag("PG 조회 잔액과 승인된 환불 기준이 일치하지 않아 취소하지 않았습니다. 결제내역을 확인해주세요.");
        }
        const cancelled = await cancelPayment({ order, reason, amount, itemIds });
        if (!cancelled.ok) return await flag(cancelled.message || "결제 취소 결과가 불확실합니다. 기존 환불 결과 확인을 이용해주세요.");
        if (cancelled.alreadyCanceled && !(amount === attempt.remaining_before && attempt.whole_order)) {
          return await flag("PG에서 이미 전액 취소된 결제입니다. 배송비를 남긴 환불액과 실제 취소금액이 달라 자동 반영하지 않았습니다.");
        }
        const after = await getPayment(order);
        if (!matchesReturnRefund(attempt, after)) return await flag("결제 취소 요청 후 거래내역 확인이 필요합니다. 다시 취소하지 말고 기존 환불 결과 확인을 이용해주세요.");
      }
    } else if (order.payment_method !== "bank_transfer") {
      return await flag("카드 결제키가 없어 환불을 실행하지 않았습니다. 결제내역을 확인해주세요.");
    }
    const completion = await supabase.rpc("admin_complete_return_refund", { p_return_id: returnId, p_token: attempt.token });
    if (completion.error) return await flag(`환불 장부 반영 실패: ${completion.error.message}. 재송금·재취소하지 말고 기존 환불 결과를 확인해주세요.`);
    return { status: 200, body: { success: true, data: completion.data, pg_cancelled: Boolean(order.payment_key) } };
  } catch (err) {
    return await flag(`환불 결과를 확인하지 못했습니다: ${err.message || "통신 오류"}. 기존 환불 결과 확인을 이용해주세요.`);
  }
}
