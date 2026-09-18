import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { assertPickupBoxTypes, buildCancelPayload, buildRegBookPayload, processPickupRegistration, processPickupReregistration } from '../api/admin/cj-pickup.js';

const cfg = { baseUrl: 'https://cj.invalid', custId: 'fixture', invcNoEndpoint: '/number', regBookEndpoint: '/register', cnclBookEndpoint: '/cancel', warehousePhone: '01000000000', boxTypeCd: '01' };
const pickup = (extra = {}) => ({ id: 1, request_number: 'PU-FIXTURE-1', status: 'pending', box_count: 2, box_type_codes: ['02', '07'], box_waybills: [], pickup_recipient_phone: '01000000000', ...extra });
function client(row) {
  const updates = [], logs = [];
  return { updates, logs, from(table) { return {
    select() { return this; }, eq() { return this; },
    async maybeSingle() { return { data: row, error: null }; },
    update(values) { updates.push(values); Object.assign(row, values); return this; },
    async insert(value) { logs.push({ table, value }); return { error: null }; },
    then(resolve) { resolve({ error: null }); },
  }; } };
}
test('운영 API와 backend 미러가 일치한다', () => {
  assert.equal(readFileSync(new URL('../api/admin/cj-pickup.js', import.meta.url), 'utf8'), readFileSync(new URL('../../frontend/apps/admin-web/api/admin/cj-pickup.js', import.meta.url), 'utf8'));
});
test('박스별 RegBook 규격은 선택값이며 env 기본 극소로 덮어쓰지 않는다', () => {
  for (const [index, code] of ['01', '02', '03', '04', '07'].entries()) {
    const body = buildRegBookPayload(pickup({ box_count: 5, box_type_codes: ['01', '02', '03', '04', '07'] }), { cfg, token: 'fixture', invcNo: '1', boxSeq: index + 1, totalBoxes: 5 });
    assert.equal(body.BOX_TYPE_CD, code); assert.equal(body.BOX_QTY, '1');
    assert.equal(body.CUST_USE_NO, index ? `PU-FIXTURE-1-B${index + 1}` : 'PU-FIXTURE-1');
  }
  for (const codes of [null, ['01'], ['01', '05'], ['01', null]]) assert.throws(() => assertPickupBoxTypes(codes, 2));
});
test('규격 미확인 요청과 잘못된 재접수는 채번·취소·DB 변경 전에 차단', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => { assert.fail('CJ must not be called'); };
  try {
    const db = client(pickup({ box_type_codes: null }));
    const result = await processPickupRegistration({ supabase: db, pickupRequestId: 1, cfg });
    assert.equal(result.code, 'PICKUP_BOX_TYPES_REQUIRED'); assert.equal(db.updates.length, 0);
    const retry = await processPickupReregistration({ supabase: db, pickupRequestId: 1, cfg, boxCount: 2, boxTypeCodes: ['07'], getToken: () => assert.fail('No token needed') });
    assert.equal(retry.code, 'PICKUP_BOX_TYPES_REQUIRED'); assert.equal(db.updates.length, 0);
  } finally { globalThis.fetch = original; }
});
test('멀티박스 일부 실패 후 재시도는 미접수 박스만 원래 규격으로 전송', async () => {
  const original = globalThis.fetch; const bodies = []; let failSecond = true, number = 0;
  globalThis.fetch = async (url, request) => {
    const body = JSON.parse(request.body).DATA;
    if (url.endsWith('/number')) return new Response(JSON.stringify({ RESULT_CD: 'S', DATA: { INVC_NO: String(++number) } }));
    assert.ok(url.endsWith('/register')); bodies.push(body);
    return new Response(JSON.stringify({ RESULT_CD: failSecond && body.CUST_USE_NO.endsWith('-B2') ? 'E' : 'S', RESULT_DETAIL: 'fixture' }));
  };
  try {
    const db = client(pickup());
    const first = await processPickupRegistration({ supabase: db, pickupRequestId: 1, cfg, token: 'fixture' });
    assert.equal(first.success, false); assert.equal(first.registeredBoxes, 1);
    db.updates[0].box_waybills[0].tracking_status = '보존할 상태';
    failSecond = false;
    const second = await processPickupRegistration({ supabase: db, pickupRequestId: 1, cfg, token: 'fixture' });
    assert.equal(second.success, true);
    assert.deepEqual(bodies.map((body) => body.BOX_TYPE_CD), ['02', '07', '07']);
    assert.deepEqual(second.pickupRequest.box_waybills.map((box) => box.box_type_cd), ['02', '07']);
    assert.equal(second.pickupRequest.box_waybills[0].tracking_status, '보존할 상태');
  } finally { globalThis.fetch = original; }
});
test('재접수 취소가 거부되면 기존 규격 유지, 새 접수 없음', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (url) => { assert.ok(url.endsWith('/cancel')); return new Response(JSON.stringify({ RESULT_CD: 'E', RESULT_DETAIL: 'already scanned' })); };
  try {
    const row = pickup({ status: 'pickup_scheduled', box_waybills: [{ box_seq: 1, tracking_number: '1', cust_use_no: 'PU-FIXTURE-1', registered_at: '2026-09-18T00:00:00Z' }] });
    const db = client(row);
    const result = await processPickupReregistration({ supabase: db, pickupRequestId: 1, cfg, boxCount: 2, boxTypeCodes: ['04', '04'], getToken: async () => 'fixture' });
    assert.equal(result.success, false); assert.equal(result.canSkipCancel, true); assert.equal(result.code, 'CJ_CANCEL_REFUSED');
    assert.equal(db.updates.length, 0); assert.deepEqual(row.box_type_codes, ['02', '07']);
  } finally { globalThis.fetch = original; }
});

test('취소는 기존 접수 규격 우선이며 규격 없는 레거시도 취소할 수 있다', () => {
  const options={cfg,token:'fixture',rcptYmd:'20260918',boxSeq:2};
  const legacy=buildCancelPayload(pickup({box_type_codes:null}),options);
  assert.equal(legacy.BOX_TYPE_CD,'01'); assert.equal(legacy.REQ_DV_CD,'02');
  const stored=buildCancelPayload(pickup({box_waybills:[{box_seq:2,tracking_number:'2',box_type_cd:'04'}]}),options);
  assert.equal(stored.BOX_TYPE_CD,'04'); assert.equal(stored.CUST_USE_NO,'PU-FIXTURE-1-B2');
  assert.equal(stored.INVC_NO,undefined);
});

test('재접수 성공은 전량 취소 후 박스 수·규격을 함께 저장하고 새 코드로 접수', async () => {
  const original = globalThis.fetch; const calls = []; let number = 10;
  globalThis.fetch = async (url, request) => {
    const body = JSON.parse(request.body).DATA; calls.push({ url, body });
    return new Response(JSON.stringify({ RESULT_CD: 'S', DATA: url.endsWith('/number') ? { INVC_NO: String(++number) } : {} }));
  };
  try {
    const row = pickup({ status: 'pickup_scheduled', box_waybills: [1,2].map((seq)=>({ box_seq: seq, tracking_number: String(seq), cust_use_no: seq===1?'PU-FIXTURE-1':'PU-FIXTURE-1-B2', registered_at: '2026-09-18T00:00:00Z' })) });
    const db = client(row);
    const result = await processPickupReregistration({ supabase: db, pickupRequestId: 1, cfg, boxCount: 3, boxTypeCodes: ['03','04','07'], desiredPickupDate:'2026-09-21', getToken: async ()=>'fixture' });
    assert.equal(result.success,true,JSON.stringify(result)); assert.equal(result.cancelledBoxes,2); assert.equal(row.box_count,3);
    assert.ok(calls.slice(0,2).every((call)=>call.url.endsWith('/cancel')));
    assert.deepEqual(calls.filter((call)=>call.url.endsWith('/register')).map((call)=>[call.body.BOX_TYPE_CD,call.body.COLCT_EXPCT_YMD]),[['03','20260921'],['04','20260921'],['07','20260921']]);
    assert.deepEqual(row.box_waybills.map((box)=>box.box_type_cd),['03','04','07']);
  } finally { globalThis.fetch=original; }
});
