// 실제 migration을 격리 PostgreSQL(PGlite)에 적용한다. 운영 데이터·송금·알림 사용 없음.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
const db = new PGlite();
const migration = name => readFileSync(new URL('../supabase/migrations/' + name, import.meta.url), 'utf8');
const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
const user = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
const change = (id, count, old) => one('select public.admin_update_shipment_box_count($1,$2,$3) as result', [id,count,old]);
const rows = async id => (await db.query('select st.* from settlements st join books b on b.id=st.book_id where b.shipment_id=$1 order by st.id',[id])).rows;
const extras = async id => (await db.query("select * from settlement_box_cost_adjustments where shipment_id=$1 and status<>'cancelled' order by id",[id])).rows;
const totals = id => one('select sum(st.box_cost_deducted)::int cost,sum(st.net_amount)::int net from settlement_payout_rows st join books b on b.id=st.book_id where b.shipment_id=$1 and st.status<>\'cancelled\'',[id]);
async function fixture(id, statuses, costs, pres = costs) {
  await db.query('insert into shipments(id,user_id,seller_name,seller_phone,box_count,box_cost_charged) values($1,$2,\'테스트\',\'01000000000\',2,$3)',[id,user,costs.reduce((a,b)=>a+b,0)]);
  for(let i=0;i<costs.length;i++) {
    const n=id*100+i;
    await db.query('insert into books(id,shipment_id,title,status) values($1,$2,\'교재\',\'settled\')',[n,id]);
    await db.query(`insert into settlements(book_id,seller_user_id,sale_amount,fee_amount,net_amount,box_cost_deducted,status,completed_at,bank_name,account_holder,account_number,account_number_ciphertext,account_number_last4)
      values($1,$2,$3,1000,$4,$5,$6,case when $6='completed' then '2026-10-01'::timestamptz end,'은행','테스트','12345678','\\x3132333435363738','5678')`,[n,user,pres[i]+1000,pres[i]-costs[i],costs[i],statuses[i]]);
  }
}
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.user',true),'')::uuid$$;
    create function is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('test.admin',true),'true')='true'$$;
    create function get_account_last4(text) returns text language sql immutable as $$select right($1,4)$$;
    create function mask_account_number(text) returns text language sql immutable as $$select '****'||$1$$;
    create function decrypt_account_number(bytea) returns text language sql immutable as $$select convert_from($1,'UTF8')$$;
    create function record_admin_operation() returns trigger language plpgsql as $$begin return new;end;$$;
    create table shipments(id bigint primary key,user_id uuid,seller_name text,seller_phone text,box_count integer default 0,box_cost_charged integer default 0,
      pickup_request_id bigint,settlement_bank_name text,settlement_account_number_ciphertext bytea,settlement_account_last4 text,settlement_account_holder text);
    create table books(id bigint primary key,shipment_id bigint references shipments(id),title text,option text,condition_grade text,status text);
    create table pickup_requests(id bigint primary key,request_number text);
    create table member_profiles(user_id uuid,name text,phone text,email text);
    create table orders(id bigint primary key,order_number text,status text,created_at timestamptz,confirmed_at timestamptz,refund_requested_at timestamptz,refund_request_resolved_at timestamptz);
    create table order_items(id bigint,title text,option_label text,condition_grade text,quantity integer);
    create table order_return_cases(order_id bigint,status text);
    create table member_settlement_accounts(id bigint,user_id uuid,bank_name text,account_holder text,account_number text,account_number_ciphertext bytea,account_number_last4 text,is_default boolean,created_at timestamptz);
    create table manual_settlements(id bigint,book_id bigint,shipment_id bigint,sale_amount integer,fee_percent numeric,fee_amount integer,net_amount integer,status text,paid_at timestamptz,sold_at date,created_at timestamptz);
    create table settlements(id bigserial primary key,seller_user_id uuid,order_id bigint,order_item_id bigint,book_id bigint references books(id),
      sale_amount integer default 0,fee_percent numeric default 0,fee_amount integer default 0,net_amount integer default 0,status text default 'pending',
      scheduled_date date default current_date,approved_at timestamptz,completed_at timestamptz,bank_name text,account_number text,account_holder text,
      created_at timestamptz default now(),updated_at timestamptz default now(),cancelled_at timestamptz,recovery_required_at timestamptz,refund_reason text,
      account_number_ciphertext bytea,account_number_last4 text,box_cost_deducted integer default 0,transfer_reference text,sale_source text default 'order',manual_sold_at timestamptz);
    grant select on shipments to authenticated;
    select set_config('test.user','${user}',false);
  `);
  const source=migration('20260901043000_nonmember_seller_auto_settlement.sql');
  const original=source.match(/create or replace function public\.admin_complete_settlements\([\s\S]*?\$\$;/i)[0];
  await db.exec(original);
  await db.exec(migration('20261102054401_shipment_box_cost_reconciliation.sql'));

  // 미지급 및 레거시 approved: 생성 순으로 재분배하고 합계 5천원만 차감.
  await fixture(1,['pending','approved','pending','pending'],[3300,3300,3300,100],[3300,3300,3300,6000]);
  await change(1,1,2);
  assert.deepEqual((await rows(1)).map(r=>r.box_cost_deducted),[3300,1700,0,0]);
  assert.deepEqual(await totals(1),{cost:5000,net:10900});
  assert.equal((await extras(1)).length,0);
  await assert.rejects(change(1,0,2),/새로고침/);
  await assert.rejects(change(1,-1,1),/박스 수/);

  // 전액 기지급: 원정산 불변, 5천원 반환 대기. 반복 저장/재증액은 중복 지급을 만들지 않는다.
  await fixture(2,['completed','completed'],[6000,4000],[9000,6000]);
  const paidBefore=await rows(2);
  await change(2,1,2);
  assert.deepEqual(await rows(2),paidBefore);
  const first=(await extras(2))[0];
  assert.equal(first.amount,5000);
  await change(2,1,1);
  assert.equal((await extras(2))[0].id,first.id);
  await change(2,2,1);
  assert.equal((await extras(2)).length,0);
  await change(2,1,2);
  const second=(await extras(2))[0];
  assert.notEqual(second.id,first.id);
  assert.equal((await one('select box_cost_charged from shipments where id=2')).box_cost_charged,5000);

  // 관리자/회원 조회에 별도 추가 지급 행이 실제 포함되고 본인 요약과 일치한다.
  const admin=(await one("select list_admin_settlements(p_statuses=>array['pending']) as r")).r;
  assert.equal(admin.rows.find(r=>r.id===second.id).book_title,'상품화 비용 조정 (추가 지급)');
  assert.equal(admin.rows.find(r=>r.id===second.id).sale_source,'box_cost_adjustment');
  const member=(await one('select get_my_settlements(200,0) as r')).r;
  assert.equal(member.rows.find(r=>r.id===second.id).book_count,0);
  assert.equal(member.rows.find(r=>r.id===second.id).box_cost_deducted,-5000);

  // 완료 직전 금액 변경/중복 요청 차단. 실제 송금 대신 완료 RPC만 격리 DB에서 실행.
  await assert.rejects(one('select admin_complete_settlement_payouts($1::jsonb)',[JSON.stringify([{id:second.id,net_amount:10000}])]),/변경/);
  const completion=(await one('select admin_complete_settlement_payouts($1::jsonb,\'추가 송금 확인\') as r',[JSON.stringify([{id:second.id,net_amount:5000}])])).r;
  assert.equal(completion.updated_count,1);
  assert.equal(completion.settlements[0].net_amount,5000);
  assert.equal((await extras(2))[0].status,'completed');
  await assert.rejects(one('select admin_complete_settlement_payouts($1::jsonb)',[JSON.stringify([{id:second.id,net_amount:5000}])]),/변경/);
  await change(2,0,1);
  assert.equal((await extras(2)).filter(a=>a.status==='pending')[0].amount,5000); // 누적 1만원 중 이미 반환한 5천원 제외
  assert.deepEqual(await rows(2),paidBefore);

  // 일부만 기지급: 지급 원금 불변, 미지급 재계산과 추가 지급 생성이 동시에 일어난다.
  await fixture(3,['completed','pending','pending'],[3300,3300,3400],[3300,3300,8000]);
  const partialBefore=(await rows(3))[0];
  await change(3,0,2);
  assert.deepEqual((await rows(3))[0],partialBefore);
  assert.equal((await extras(3))[0].amount,3300);
  assert.deepEqual((await rows(3)).slice(1).map(r=>r.box_cost_deducted),[0,0]);
  assert.equal((await totals(3)).cost,0);
  // 일반 정산+추가 지급 일괄 완료도 단일 트랜잭션.
  const mixed=(await db.query("select st.id,st.net_amount from settlement_payout_rows st join books b on b.id=st.book_id where b.shipment_id=3 and st.status='pending'")).rows;
  const mixedResult=(await one('select admin_complete_settlement_payouts($1::jsonb) as r',[JSON.stringify(mixed)])).r;
  assert.equal(mixedResult.updated_count,3);
  assert.equal(mixedResult.settlements.reduce((n,r)=>n+r.net_amount,0),14600);

  // 증액: 기지급 반환은 유지하고 아직 지급하지 않은 판매분에서 비용을 차감한다.
  await fixture(4,['completed','pending'],[10000,0],[13000,8000]);
  await change(4,1,2);
  const adj=(await extras(4))[0];
  await one('select admin_complete_settlement_payouts($1::jsonb)',[JSON.stringify([{id:adj.id,net_amount:5000}])]);
  await change(4,2,1);
  assert.equal((await rows(4))[1].box_cost_deducted,5000);
  await change(4,1,2);
  assert.equal((await rows(4))[1].box_cost_deducted,0);
  assert.equal((await extras(4)).filter(a=>a.status==='pending').length,0);

  // 판매수익 부족은 음수 정산 없이 이후 판매로 이월.
  await fixture(5,['pending'],[3000],[3000]);
  await change(5,3,2);
  assert.equal((await rows(5))[0].net_amount,0);
  assert.equal((await one('select box_cost_charged from shipments where id=5')).box_cost_charged,3000);
  await db.exec("insert into shipments(id,box_count) values(6,0)");
  await change(6,2,0);
  assert.equal((await extras(6)).length,0);

  // 원주문 환불 보류 시 박스 변경과 추가 지급 모두 원자적으로 거부.
  await fixture(7,['completed'],[10000],[12000]);
  await db.exec("insert into orders(id,status,refund_requested_at) values(7,'confirmed',now()); update settlements set order_id=7 where book_id=700;");
  await assert.rejects(change(7,1,2),/환불/);
  assert.equal((await one('select box_count from shipments where id=7')).box_count,2);
  await db.exec('update orders set refund_request_resolved_at=now() where id=7');
  await change(7,1,2);
  const held=(await extras(7))[0];
  await db.exec('update orders set refund_request_resolved_at=null where id=7');
  await assert.rejects(one('select admin_complete_settlement_payouts($1::jsonb)',[JSON.stringify([{id:held.id,net_amount:5000}])]),/환불/);

  // RLS: 본인만 조회, 직접 원장 변경·구 지급 API·내부 view 접근 불가.
  await db.exec("select set_config('test.admin','false',false); set role authenticated;");
  assert.ok((await db.query('select id from settlement_box_cost_adjustments')).rows.length>0);
  await assert.rejects(db.query('update settlement_box_cost_adjustments set amount=1'),/permission denied/);
  await assert.rejects(db.query('select * from settlement_payout_rows'),/permission denied/);
  await assert.rejects(db.query("select admin_complete_settlements('{}')"),/permission denied/);
  await assert.rejects(change(1,0,1),/Admin/);
  await db.exec(`select set_config('test.user','${other}',false);`);
  assert.equal((await db.query('select id from settlement_box_cost_adjustments')).rows.length,0);
  assert.equal((await one('select get_my_settlements() as r')).r.rows.length,0);
  await db.exec('reset role; set role anon;');
  await assert.rejects(db.query('select * from settlement_box_cost_adjustments'),/permission denied/);
  await assert.rejects(db.query("select admin_update_shipment_box_count(1,0,1)"),/permission denied/);
  console.log('PASS: unpaid/approved, paid immutable, mixed payout, repeated edits, cost increases, carryover, stale/duplicate payout, refund holds, seller queries, RLS.');
} catch(error) {
  console.error(JSON.stringify({message:error.message,code:error.code,detail:error.detail,where:error.where,position:error.position,stack:error.code ? undefined : error.stack}));
  process.exitCode=1;
} finally { await db.close(); }
