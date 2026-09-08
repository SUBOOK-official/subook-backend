// 수거 자동 추적: 주문 배송 크론과 분리. 수동 조회와 동일한 박스별 집계·전진 가드 사용.
// https://vercel.com/docs/cron-jobs/manage-cron-jobs
import { createServiceClient, getCjConfig, getOneDayToken, PICKUP_SELECT, refreshPickupTracking } from './cj-tracking.js';

export const config = { maxDuration: 300 };
export default async function handler(req, res) {
  if (req.method !== 'GET') { res.setHeader('Allow','GET'); return res.status(405).json({ error: 'Method not allowed', code: 405 }); }
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized', code: 401 });
  }
  const dryRun = String(req.query?.dryRun || '') === '1';
  const started = Date.now();
  try {
    const supabase = createServiceClient();
    const { data, error } = await supabase.from('pickup_requests').select(PICKUP_SELECT)
      .in('status',['pickup_scheduled','picking_up']).is('merged_into_id',null)
      .or('tracking_number.not.is.null,box_waybills.neq.[]')
      .order('cj_tracking_last_checked_at',{ ascending:true, nullsFirst:true }).order('id').limit(50);
    if (error) throw error;
    const targets = data || [];
    const summary = { success:true, dryRun, targets:targets.length, checked:0, failed:0, skipped:0, results:[] };
    if (!targets.length) return res.status(200).json(summary);
    const cfg = getCjConfig();
    const token = await getOneDayToken(cfg);
    const deadline = started + 245000;
    for (const pickup of targets) {
      if (Date.now() > deadline - 42000) { summary.skipped += targets.length-summary.results.length; break; }
      try {
        const result = await refreshPickupTracking(supabase,pickup,{ cfg,token,dryRun,deadline });
        if (result.skipped) summary.skipped += 1;
        else summary.checked += 1;
        summary.results.push({ id:pickup.id, previousStatus:pickup.status, status:result.nextStatus || result.pickupRequest?.status, skipped:result.skipped || null });
      } catch (err) {
        summary.failed += 1;
        summary.results.push({ id:pickup.id, error:err.message });
        if (!dryRun) {
          // 실패한 항목도 시도 시각을 남겨 다음 실행에서 나머지 오래된 항목에 차례가 간다.
          const { error: stampError } = await supabase.from('pickup_requests')
            .update({ cj_tracking_last_checked_at:new Date().toISOString() })
            .eq('id',pickup.id).eq('updated_at',pickup.updated_at);
          if (stampError) console.error('[cj-pickup-tracking] failed to save attempt',pickup.id,stampError.message);
          const { error: logError } = await supabase.from('pickup_logistics_events').insert({ pickup_request_id:pickup.id,
            event_type:'tracking_lookup',status:'failed',error_message:err.message,payload:{ source:'cron' } });
          if (logError) console.error('[cj-pickup-tracking] failed to save log',pickup.id,logError.message);
        }
      }
    }
    summary.success = summary.failed === 0;
    console.log('[cj-pickup-tracking]',JSON.stringify(summary));
    return res.status(summary.failed ? 207 : 200).json(summary);
  } catch (error) {
    console.error('[cj-pickup-tracking]',error.message);
    return res.status(500).json({ error:'수거 자동 추적에 실패했습니다.',code:500 });
  }
}
