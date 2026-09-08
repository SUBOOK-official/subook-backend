import test from 'node:test';
import assert from 'node:assert/strict';
import { refreshPickupTracking } from './cj-tracking.js';
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
