import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';
const source = readFileSync(new URL('../docs/gsheet-sync-appsscript.gs', import.meta.url), 'utf8');

function harness(data) {
  const events=[];
  const sheet={
    getLastRow:()=>data.length,
    getLastColumn:()=>data[0].length,
    getRange:(r,c,n,m)=>({
      getValues:()=>Array.from({length:n},(_,i)=>Array.from({length:m},(_,j)=>data[r+i-1]?.[c+j-1]??'')),
      setNumberFormats:()=>events.push('format'),
      setValues:values=>{events.push('write');values.forEach((row,i)=>row.forEach((value,j)=>{
        data[r+i-1]??=[];data[r+i-1][c+j-1]=value;
      }));},
    }),
  };
  const context=vm.createContext({
    SpreadsheetApp:{getActiveSpreadsheet:()=>({getSheetByName:()=>sheet}),flush:()=>events.push('flush')},
    LockService:{getScriptLock:()=>({tryLock:()=>true,releaseLock:()=>events.push('unlock')})},
    ContentService:{MimeType:{JSON:'json'},createTextOutput:text=>({setMimeType:()=>JSON.parse(text)})},
  });
  vm.runInContext(source,context);
  return {context,events,data,post:(kind,rows)=>context.doPost({postData:{contents:JSON.stringify({token:context.SHARED_TOKEN,kind,rows})}})};
}
test('일련번호 없는 배치는 쓰기 없이 거부',()=>{
  const h=harness([['id','location','seller','title','price','option']]);
  assert.equal(h.post('inventory',[[1,'','','a',100,''],[null,'','','b',100,'']]).error,'missing_serial_number');
  assert.ok(!h.events.includes('write'));
});
test('재전송 및 같은 배치의 중복을 제거하고 flush 후 락 해제',()=>{
  const h=harness([['id','location','seller','title','price','option']]);
  assert.equal(h.post('inventory',[[1,'','','a',100,''],[1,'','','a',100,'']]).appended,1);
  assert.equal(h.post('inventory',[[1,'','','a',100,'']]).appended,0);
  assert.equal(h.data.length,2);
  assert.ok(h.events.indexOf('flush')<h.events.indexOf('unlock'));
});
test('판매 주문번호/헤더 누락은 쓰기 전에 거부',()=>{
  const h=harness([['상품 이름']]);
  assert.equal(h.post('sale',[{'상품 이름':'a'}]).error,'missing_order_number');
  assert.equal(h.post('sale',[{'주문 번호':'ORD-1'}]).error,'missing_order_header');
  assert.ok(!h.events.includes('write'));
});
test('부분 기록 주문은 같은 행의 빈 셀만 복구하고 수식 열을 보존',()=>{
  const h=harness([['주문 번호','상품 이름','정산자명','구매 수량'],['ORD-1','','formula',2]]);
  const rows=[{'주문 번호':'ORD-1','상품 이름':'book','구매 수량':2}];
  assert.equal(h.post('sale',rows).repairedCells,1);
  assert.deepEqual(h.data[1],['ORD-1','book','formula',2]);
  assert.equal(h.post('sale',rows).repairedCells,0);
});
test('기존 주문과 값/품목 수가 다르면 덮어쓰지 않음',()=>{
  const h=harness([['주문 번호','상품 이름'],['ORD-1','original']]);
  assert.equal(h.post('sale',[{'주문 번호':'ORD-1','상품 이름':'different'}]).error,'existing_order_conflict');
  assert.ok(!h.events.includes('write'));
});
