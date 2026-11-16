import test from 'node:test';
import assert from 'node:assert/strict';
import { getOneDayToken, refreshPickupTracking } from './cj-tracking.js';
import handler from './cj-pickup-tracking.js';
const cfg={baseUrl:'https://cj.example.invalid',trackingEndpoint:'/track',custId:'fixture'};
const pickup=(overrides={})=>({id:1,status:'pickup_scheduled',updated_at:'2026-09-08T00:00:00Z',tracking_number:'111111111111',box_count:2,box_waybills:[{box_seq:1,tracking_number:'111111111111'},{box_seq:2,tracking_number:'222222222222',tracking_status:'이전 상태'}],...overrides});
function client(row,concurrent=false){
  const updates=[],logs=[];
  return {updates,logs,from(table){const builder={
    values:null,select(){if(this.values)return Promise.resolve({data:concurrent?[]:[{id:row.id}],error:null});return this;},
    update(values){this.values=values;updates.push(values);return this;},eq(){return this;},
    maybeSingle(){return Promise.resolve({data:{...row,...updates.at(-1)},error:null});},
    insert(value){logs.push({table,value});return Promise.resolve({error:null});}
  };return builder;}};
}
async function lookup(row,replies,options={}){
  const original=globalThis.fetch;
  globalThis.fetch=async (_url,request)=>{
    const number=JSON.parse(request.body).DATA.INVC_NO;
    const reply=replies[number];
    return new Response(JSON.stringify(reply),{status:200,headers:{'content-type':'application/json'}});
  };
  const db=client(row,options.concurrent);
  try{return {result:await refreshPickupTracking(db,row,{cfg,token:'fixture',...options}),db};}
  finally{globalThis.fetch=original;}
}
const arrived={RESULT_CD:'S',DATA:[{CRG_ST:'91',CRG_ST_NM:'배송완료',SCAN_YMD:'2026-09-08',SCAN_HOUR:'11:00'}]};
const noData={RESULT_CD:'E',RESULT_DETAIL:'no data'};
test('모든 박스 도착 때만 입고, dry-run은 쓰기 없음',async()=>{
  const replies={'111111111111':arrived,'222222222222':arrived};
  const dry=await lookup(pickup(),replies,{dryRun:true});assert.equal(dry.result.nextStatus,'arrived');assert.equal(dry.db.updates.length,0);
  const live=await lookup(pickup(),replies);assert.equal(live.db.updates[0].status,'arrived');assert.equal(live.db.logs.length,2);
});
test('미스캔·미접수 박스가 남으면 입고로 넘기지 않는다',async()=>{
  const partial=await lookup(pickup(),{'111111111111':arrived,'222222222222':noData});assert.equal(partial.db.updates[0].status,'picking_up');
  const waiting=await lookup(pickup(),{'111111111111':noData,'222222222222':noData});assert.equal(waiting.db.updates[0].status,'pickup_scheduled');
  const missing=await lookup(pickup({box_count:3}),{'111111111111':arrived,'222222222222':arrived});assert.equal(missing.db.updates[0].status,'picking_up');
});
test('일부 실패는 성공 박스만 병합하고 기존 박스 정보를 보존한다',async()=>{
  const partial=await lookup(pickup(),{'111111111111':arrived,'222222222222':{RESULT_CD:'E',RESULT_DETAIL:'temporary error'}});
  assert.equal(partial.db.updates[0].box_waybills[1].tracking_status,'이전 상태');assert.equal(partial.db.updates[0].status,'picking_up');
});
test('검수완료 상태 유지, 동시 변경 시 추적 저장·로그 건너뛰기',async()=>{
  const replies={'111111111111':arrived,'222222222222':arrived};
  const finished=await lookup(pickup({status:'inspected'}),replies);assert.equal(finished.db.updates[0].status,'inspected');
  const raced=await lookup(pickup(),replies,{concurrent:true});assert.equal(raced.result.skipped,'concurrent_change');assert.equal(raced.db.logs.length,0);
});
test('자동 조회는 CRON_SECRET 없거나 일치하지 않으면 차단한다',async()=>{
  const secret=process.env.CRON_SECRET;process.env.CRON_SECRET='fixture-secret';
  try{for(const authorization of [undefined,'Bearer wrong']){
    let status;const response={setHeader(){},status(code){status=code;return this;},json(){return this;}};
    await handler({method:'GET',headers:{authorization}},response);assert.equal(status,401);
  }}finally{if(secret===undefined)delete process.env.CRON_SECRET;else process.env.CRON_SECRET=secret;}
});
test('일시적인 연결 실패는 토큰 발급과 추적에서 재시도한다',async()=>{
  const original=globalThis.fetch;
  try{
    let calls=0;
    globalThis.fetch=async()=>{
      if(++calls===1)throw new TypeError('fetch failed',{cause:{code:'ECONNRESET'}});
      return new Response(JSON.stringify({RESULT_CD:'S',DATA:{TOKEN_NUM:'fixture-token'}}));
    };
    assert.equal(await getOneDayToken({...cfg,tokenEndpoint:'/token'}),'fixture-token');assert.equal(calls,2);
    calls=0;
    globalThis.fetch=async()=>{
      if(++calls===1)throw new TypeError('fetch failed',{cause:{code:'UND_ERR_CONNECT_TIMEOUT'}});
      return new Response(JSON.stringify(arrived));
    };
    const row=pickup({box_count:1,box_waybills:[]}),db=client(row);
    await refreshPickupTracking(db,row,{cfg,token:'fixture'});
    assert.equal(calls,2);assert.equal(db.updates[0].status,'arrived');
  }finally{globalThis.fetch=original;}
});
test('연결 실패가 계속되면 제한 횟수 뒤 중단하고 수거 상태를 보존한다',async()=>{
  const original=globalThis.fetch;let calls=0;
  globalThis.fetch=async()=>{calls++;throw new TypeError('fetch failed',{cause:{code:'ECONNRESET'}});};
  const row=pickup({box_count:1,box_waybills:[]}),db=client(row);
  try{
    await assert.rejects(refreshPickupTracking(db,row,{cfg,token:'fixture'}),/fetch failed/);
    assert.equal(calls,3);assert.equal(db.updates.length,0);assert.equal(db.logs.length,0);
  }finally{globalThis.fetch=original;}
});
// '미집화'(운영 실측 스캔코드 12) — 기사가 수거하러 갔지만 가져가지 못한 상태 (2026-11-16)
const scan=(name,hour,code='')=>({CRG_ST:code,CRG_ST_NM:name,SCAN_YMD:'2026-09-08',SCAN_HOUR:hour});
const departed={RESULT_CD:'S',DATA:[scan('집화출발','09:00')]};
const uncollected={RESULT_CD:'S',DATA:[scan('집화출발','09:00'),scan('미집화','18:00','12')]};
const collected={RESULT_CD:'S',DATA:[scan('집화출발','09:00'),scan('집화처리','15:00','11')]};
test("'미집화'는 글자에 '집화'가 있어도 수거중으로 넘기지 않는다",async()=>{
  const both=await lookup(pickup(),{'111111111111':uncollected,'222222222222':uncollected});
  assert.equal(both.db.updates[0].status,'pickup_scheduled');
  assert.equal(both.db.updates[0].cj_tracking_status,'박스1 미집화 · 박스2 미집화');
  const single=pickup({box_count:1,box_waybills:[]});
  const one=await lookup(single,{'111111111111':uncollected});assert.equal(one.db.updates[0].status,'pickup_scheduled');
  // 기사가 출발만 한 상태와 실제 수거는 그대로 수거중
  const onTheWay=await lookup(pickup(),{'111111111111':departed,'222222222222':departed});assert.equal(onTheWay.db.updates[0].status,'picking_up');
});
test('수거중으로 넘어갔던 건은 조회한 박스가 전부 미집화일 때만 수거접수로 되돌린다',async()=>{
  const stuck=pickup({status:'picking_up'});
  const healed=await lookup(stuck,{'111111111111':uncollected,'222222222222':uncollected});assert.equal(healed.db.updates[0].status,'pickup_scheduled');
  // 한 박스라도 실제로 수거됐거나 아직 스캔이 없으면 되돌리지 않는다
  const mixed=await lookup(stuck,{'111111111111':uncollected,'222222222222':collected});assert.equal(mixed.db.updates[0].status,'picking_up');
  const unknown=await lookup(stuck,{'111111111111':uncollected,'222222222222':noData});assert.equal(unknown.db.updates[0].status,'picking_up');
  // 입고·검수 이후 상태는 건드리지 않는다
  for(const status of ['arrived','inspecting','inspected']){
    const later=await lookup(pickup({status}),{'111111111111':uncollected,'222222222222':uncollected});assert.equal(later.db.updates[0].status,status);
  }
});
// 'SM입고'(실측 코드 21)는 출발지 터미널 입고 — 수북 입고가 아니라 이동 중 (2026-11-16)
const smInbound={RESULT_CD:'S',DATA:[scan('집화출발','05:46','13'),scan('집화처리','17:54','11'),scan('SM입고','19:07','21')]};
const outForDelivery={RESULT_CD:'S',DATA:[scan('집화처리','09:00','11'),scan('간선하차','12:00','42'),scan('배송출발','13:48','82')]};
const undelivered={RESULT_CD:'S',DATA:[scan('배송출발','13:48','82'),scan('미배송','18:00','84')]};
test("'SM입고'·배송출발·미배송은 입고가 아니라 수거중, 입고는 배송완료일 때만",async()=>{
  const single=(overrides={})=>pickup({box_count:1,box_waybills:[],...overrides});
  for(const reply of [smInbound,outForDelivery,undelivered]){
    const moving=await lookup(single(),{'111111111111':reply});assert.equal(moving.db.updates[0].status,'picking_up');
  }
  const done=await lookup(single({status:'picking_up'}),{'111111111111':arrived});assert.equal(done.db.updates[0].status,'arrived');
  // 두 박스가 모두 SM입고여도 입고로 넘기지 않는다
  const both=await lookup(pickup(),{'111111111111':smInbound,'222222222222':smInbound});assert.equal(both.db.updates[0].status,'picking_up');
});
