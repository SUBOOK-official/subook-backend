const HISTORY_SELECT = 'id,order_id,request_key,reason,items,state,tracking_number,created_at,updated_at';

export async function listOrderReshipments(supabase, orderId) {
  const { data, error } = await supabase.from('order_reshipments').select(HISTORY_SELECT)
    .eq('order_id', orderId).order('id', { ascending: false });
  if (error) throw error;
  return data ?? [];
}

function labelOrder(order, shipment) {
  return {
    ...order,
    // 원 주문 및 합배송 키와 절대 겹치지 않는 재발송 전용 CJ 관리번호.
    order_number: `RS-${shipment.id}`,
    order_numbers: [order.order_number],
    item_count: shipment.items.reduce((total, item) => total + item.quantity, 0),
    order_items: shipment.items.map((item) => ({
      id: item.orderItemId, title: item.title, quantity: item.quantity, unit_price: 0,
    })),
    tracking_number: shipment.tracking_number,
    tracking_carrier: 'CJ대한통운',
  };
}

export async function processOrderReshipment({ supabase, orderId, body, adminId, token, cfg,
  getOrder, registerCjDelivery, buildSenderForLabel }) {
  let shipment = null;
  let bookingStarted = false;
  const transition = async (action, extra = {}) => {
    const { data, error } = await supabase.rpc('admin_transition_order_reshipment', {
      p_reshipment_id: shipment.id, p_claim_token: shipment.claim_token, p_action: action, ...extra,
    });
    if (error) throw error;
    return data;
  };
  try {
    if (body.reshipmentAction === 'reprint') {
      const { data, error } = await supabase.from('order_reshipments').select('*')
        .eq('order_id', orderId).eq('id', body.reshipmentId).single();
      if (error) throw error;
      shipment = data;
      if (shipment.state !== 'registered') throw new Error('발급 완료된 재발송 송장만 재출력할 수 있습니다.');
    } else {
      const { data, error } = await supabase.rpc('admin_claim_order_reshipment', {
        p_order_id: orderId, p_request_key: body.requestKey, p_created_by: adminId,
        p_reason: body.reason, p_items: body.items, p_expected_latest_id: body.expectedLatestId ?? null,
      });
      if (error) throw error;
      shipment = data;
    }
    const order = await getOrder(supabase, orderId);
    if (!order) throw new Error('주문을 찾을 수 없습니다.');
    const reprint = shipment.state === 'registered';
    if (!reprint) {
      await registerCjDelivery(labelOrder(order, shipment), {
        token, cfg, allowDuplicateRecovery: false,
        beforeBooking: async (trackingNumber, addr) => {
          shipment = await transition('booking', { p_tracking_number: trackingNumber, p_routing_data: addr });
          bookingStarted = true;
        },
      });
      shipment = await transition('registered');
    }
    return {
      success: true, orderId, reshipmentId: shipment.id, status: reprint ? 'reprint' : 'registered',
      orderNumber: order.order_number, trackingNumber: shipment.tracking_number,
      addr: shipment.routing_data, sender: buildSenderForLabel(cfg), order: labelOrder(order, shipment),
    };
  } catch (error) {
    if (shipment && bookingStarted && error.bookingRejected) {
      try { await transition('rejected'); bookingStarted = false; } catch { /* 불명확하면 선점 보존 */ }
    }
    if (shipment?.state === 'claimed' && !bookingStarted) {
      try { await transition('failed'); } catch { /* 10분 후 같은 요청으로만 복구 */ }
    }
    return { success: false, orderId, reshipmentId: shipment?.id, status: 'failed',
      error: bookingStarted
        ? `CJ 접수 결과 확인이 필요합니다 (운송장 ${shipment.tracking_number}). 새 송장을 발급하지 말고 이력을 확인해 주세요.`
        : error.message || '재발송 송장 처리에 실패했습니다. 이력을 새로고침해 주세요.',
    };
  }
}
