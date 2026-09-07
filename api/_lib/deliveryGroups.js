// CJ에는 실제 한 박스의 전체 품목을 전달한다. 원 주문번호/금액은 변경하지 않는다.
export function deliveryRevision(orders) {
  return JSON.stringify([...orders].sort((a, b) => a.id - b.id).map((order) => [
    order.id, order.user_id, order.status, order.tracking_number,
    order.shipping_recipient_name, order.shipping_recipient_phone, order.shipping_postal_code,
    order.shipping_address_line1, order.shipping_address_line2, order.shipping_memo,
    [...(order.order_items ?? [])].sort((a, b) => a.id - b.id)
      .map((item) => [item.id, item.quantity, item.refunded_at]),
  ]));
}

export function combineDeliveryOrders(orders) {
  const sorted = [...orders].sort((a, b) => a.id - b.id);
  const items = sorted.flatMap((order) => (order.order_items ?? [])
    .filter((item) => !item.refunded_at)
    .map((item) => ({ ...item, order_number: order.order_number })));
  return {
    ...sorted[0],
    order_numbers: sorted.map((order) => order.order_number),
    order_items: items,
    item_count: items.reduce((sum, item) => sum + Number(item.quantity || 1), 0),
    shipping_memo: [...new Set(sorted.map((order) => order.shipping_memo?.trim()).filter(Boolean))].join(' / '),
  };
}

// 서로 다른 요청/청크에 동일 합배송 주문이 들어와도 운송장 한 장만 인쇄한다.
export function uniqueDeliveryLabels(results) {
  const seen = new Set();
  return results.filter((row) => {
    const key = String(row.trackingNumber || '').replace(/\D/g, '');
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
