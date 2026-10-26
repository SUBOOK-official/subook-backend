import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const read = (file) => readFileSync(new URL(`../supabase/migrations/${file}`, import.meta.url), 'utf8');
const functionSql = (file, name) => {
  const match = read(file).match(new RegExp(`create (?:or replace )?function public\\.${name}\\([\\s\\S]*?AS (\\$[a-z_]*\\$)[\\s\\S]*?\\1\\s*;`, 'i'));
  assert.ok(match, name);
  return match[0];
};
const owner = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';

test('수동 판매 정산: 생성부터 조회·지급까지 기존 원장과 연결', async (t) => {
  const db = new PGlite();
  const value = async (sql, params = []) => (await db.query(sql, params)).rows[0]?.result;
  const sold = (id) => value('select admin_mark_book_sold($1) as result', [id]);
  const settlement = async (id) => (await db.query('select * from settlements where book_id=$1', [id])).rows[0];
  const book = async (id) => (await db.query('select status,is_public,price from books where id=$1', [id])).rows[0];
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.test_user',true),'')::uuid$$;
      create function is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('app.test_admin',true),'true')='true'$$;
      -- 계좌 암복호화는 이 변경의 대상이 아니므로 테스트용 마스킹 헬퍼를 사용한다.
      create function get_account_last4(text) returns text language sql immutable as $$select right($1,4)$$;
      create function mask_account_number(text) returns text language sql immutable as $$select '****' || right($1,4)$$;
      create function decrypt_account_number(bytea) returns text language sql immutable as $$select convert_from($1,'UTF8')$$;
      create table pickup_requests(id bigint primary key, request_number text);
      create table shipments(id bigint primary key,user_id uuid,pickup_date date,fee_policy_version text,
        is_direct_purchase boolean default false,box_count integer default 1,box_cost_charged integer default 0,
        settlement_bank_name text default '테스트은행',settlement_account_holder text default '테스트판매자',
        settlement_account_number_ciphertext bytea default convert_to('1234567890','UTF8'),settlement_account_last4 text default '7890',
        pickup_request_id bigint,seller_name text default '테스트판매자',seller_phone text default '01000000000');
      create table books(id bigint primary key,shipment_id bigint references shipments(id),status text default 'on_sale',
        is_public boolean default true,price integer default 7000,condition_grade text default 'S',title text default '테스트교재',option text);
      create table orders(id bigint primary key,status text,order_number text,confirmed_at timestamptz,created_at timestamptz default now(),
        refund_requested_at timestamptz,refund_request_resolved_at timestamptz);
      create table order_items(id bigint primary key,order_id bigint references orders(id),book_id bigint references books(id),
        refunded_at timestamptz,quantity integer default 1,unit_price integer default 7000,total_price integer default 7000,
        title text,option_label text,condition_grade text);
      create table order_return_cases(order_id bigint,status text);
      create table member_settlement_accounts(id bigint primary key,user_id uuid,bank_name text,account_number text,
        account_number_ciphertext bytea,account_number_last4 text,account_holder text,is_default boolean,created_at timestamptz default now());
      create table member_profiles(user_id uuid primary key,name text,phone text,email text);
      insert into auth.users values('${owner}'),('${other}');
      insert into member_profiles values('${owner}','테스트판매자','01000000000','test@example.invalid');
      insert into shipments(id,user_id,pickup_date,box_cost_charged) values(78,'${owner}','2026-09-07',5000);
      insert into shipments(id,user_id,pickup_date,fee_policy_version) values(79,'${owner}','2026-10-01','2026-09');
      insert into shipments(id,user_id,pickup_date,box_count) values(80,'${other}','2026-01-01',0),(81,null,'2026-09-07',0);
      insert into shipments(id,user_id,is_direct_purchase) values(82,'${owner}',true);
      insert into books(id,shipment_id,status,is_public) values(7905,78,'settled',false);
      insert into books(id,shipment_id) select n,78 from generate_series(1,20) n;
      update books set shipment_id=79 where id in(2,3);
      update books set shipment_id=80 where id=4;
      update books set shipment_id=81 where id=5;
      update books set shipment_id=82 where id=6;
      update books set shipment_id=null where id=7;
      update books set price=0 where id=8;
      update books set status='reserved' where id=9;
      update books set condition_grade='DISCARD' where id=10;
      insert into orders(id,status,order_number,confirmed_at) values(1,'confirmed','ORD1',now()),(2,'cancelled','ORD2',null);
      insert into order_items(id,order_id,book_id) values(1,1,11),(2,2,12);
      set app.test_user='${owner}';
    `);
    // 실제 기존 테이블 정의와 RLS를 사용해 새 migration 이후에도 권한이 유지되는지 검증한다.
    const ledger = read('2026041203_settlement_automation.sql');
    await db.exec(ledger.slice(ledger.indexOf('create table if not exists public.settlements'), ledger.indexOf('create or replace function public.touch_settlements_updated_at')));
    await db.exec(`alter table settlements drop constraint settlements_status_check;
      alter table settlements add constraint settlements_status_check check(status in('pending','approved','completed','cancelled','recovery_required'));
      alter table settlements add column account_number_ciphertext bytea, add column account_number_last4 text,
        add column box_cost_deducted integer not null default 0,add column transfer_reference text,
        add column cancelled_at timestamptz,add column refund_reason text;
      grant select,insert,update,delete on settlements to authenticated;
      grant usage on schema auth to authenticated;
    `);
    const legacy = read('20260629000000_manual_settlements.sql');
    await db.exec(legacy.slice(legacy.indexOf('create table if not exists public.manual_settlements'), legacy.indexOf('create index if not exists manual_settlements_status_idx')));
    for (const [file, name] of [
      ['2026041203_settlement_automation.sql', 'calculate_settlement_fee_percent'],
      ['20260910054749_pickup_fee_policy_versions.sql', 'calculate_settlement_fee_percent'],
      ['20260702130000_monthly_settlement_schedule.sql', 'next_settlement_date'],
      ['20260901043000_nonmember_seller_auto_settlement.sql', 'admin_complete_settlements'],
      ['20260901043000_nonmember_seller_auto_settlement.sql', 'admin_list_settlement_payouts'],
      ['20260809095729_manual_settlement_auto_dedupe.sql', 'admin_commit_manual_settlement'],
    ]) await db.exec(functionSql(file, name));
    await db.exec(read('20261026025534_manual_sale_pending_settlements.sql'));

    await t.test('관리자만 실행, 일반회원·익명은 재고/정산 변경 불가', async () => {
      assert.equal(await value("select has_function_privilege('anon','admin_mark_book_sold(bigint)','execute') as result"), false);
      await db.exec("set app.test_admin='false'");
      await assert.rejects(sold(1), /관리자만/);
      assert.equal((await book(1)).status, 'on_sale');
      assert.equal(await settlement(1), undefined);
      await db.exec("set app.test_admin='true'");
    });

    await t.test('3494와 같은 이미 판매완료·비용차감된 교재를 익월 1일 정산대기로 보완', async () => {
      const result = await sold(7905);
      assert.equal(result.already_sold, true);
      assert.equal(result.settlement_created, true);
      const row = await settlement(7905);
      assert.equal(row.sale_amount, 7000);
      assert.equal(Number(row.fee_percent), 45);
      assert.equal(row.fee_amount, 3150);
      assert.equal(row.net_amount, 3850);
      assert.equal(row.box_cost_deducted, 0);
      assert.equal(row.status, 'pending');
      assert.equal(row.sale_source, 'manual_sale');
      assert.equal(row.order_id, null);
      assert.equal(row.order_item_id, null);
      assert.equal(row.seller_user_id, owner);
      assert.equal(row.scheduled_date.getTime(), (await value('select next_settlement_date(now()) as result')).getTime());
      assert.equal(await value('select box_cost_charged as result from shipments where id=78'), 5000);
      assert.equal((await book(1)).status, 'on_sale');
    });

    await t.test('정상 판매는 재고 제외와 정산 생성이 함께 반영되고 재실행은 멱등', async () => {
      const result = await sold(1);
      assert.equal(result.already_sold, false);
      assert.deepEqual(await book(1), { status: 'settled', is_public: false, price: 7000 });
      const before = await settlement(1);
      assert.equal((await sold(1)).settlement_created, false);
      assert.deepEqual(await settlement(1), before);
      assert.equal(await value('select count(*)::int as result from settlements where book_id=1'), 1);
    });

    await t.test('정책 스냅샷과 수거별 남은 상품화 비용 차감/이월을 적용', async () => {
      await sold(2);
      let row = await settlement(2);
      assert.equal(Number(row.fee_percent), 50);
      assert.equal(row.fee_amount, 3500);
      assert.equal(row.box_cost_deducted, 3500);
      assert.equal(row.net_amount, 0);
      await sold(2);
      assert.equal(await value('select box_cost_charged as result from shipments where id=79'), 3500);
      await sold(3);
      row = await settlement(3);
      assert.equal(row.box_cost_deducted, 1500);
      assert.equal(row.net_amount, 2000);
      assert.equal(await value('select box_cost_charged as result from shipments where id=79'), 5000);
      await sold(4);
      assert.equal(Number((await settlement(4)).fee_percent), 35);
    });

    await t.test('비회원 위탁도 정산 대상이며 자체매입/자체판매는 제외', async () => {
      await sold(5);
      assert.equal((await settlement(5)).seller_user_id, null);
      assert.equal((await settlement(5)).net_amount, 3850);
      for (const id of [6,7]) {
        assert.equal((await sold(id)).settlement_excluded, 'direct_purchase');
        assert.equal(await settlement(id), undefined);
        assert.equal((await book(id)).status, 'settled');
      }
    });

    await t.test('가격·상태·진행 주문 오류는 비용/재고/원장 모두 그대로 유지', async () => {
      const balance = await value('select sum(box_cost_charged)::int as result from shipments');
      for (const [id, message] of [[8,/판매가/],[9,/판매중/],[10,/판매중/],[11,/진행 중인 주문/],[999,/찾을 수 없습니다/]]) {
        const before = await book(id);
        await assert.rejects(sold(id), message);
        assert.deepEqual(await book(id), before);
        assert.equal(await settlement(id), undefined);
      }
      assert.equal(await value('select sum(box_cost_charged)::int as result from shipments'), balance);
      await sold(12); // 취소 주문의 재고는 판매 가능
    });

    await t.test('기존 플랫폼/엑셀/취소 정산은 덮어쓰거나 이중 생성하지 않음', async () => {
      await db.exec(`insert into settlements(order_id,book_id,sale_amount,fee_percent,fee_amount,net_amount,scheduled_date,status)
        values(2,13,7000,45,3150,3850,current_date,'cancelled');
        insert into manual_settlements(book_id,shipment_id,status) values(14,78,'unpaid'),(15,78,'paid'),(16,78,'cancelled');`);
      for (const id of [13,14,15,16]) {
        const before = await book(id);
        await assert.rejects(sold(id), /이미 정산 이력/);
        assert.deepEqual(await book(id), before);
      }
      await assert.rejects(db.exec('insert into manual_settlements(book_id,shipment_id) values(1,78)'), /수동 판매완료 정산이 이미 존재/);
      await assert.rejects(db.exec("update manual_settlements set book_id=1,status='unpaid' where book_id=16"), /수동 판매완료 정산이 이미 존재/);
      const before = await settlement(2);
      await assert.rejects(value(`select admin_commit_manual_settlement('[{"book_id":2,"sale_amount":9000}]'::jsonb,true) as result`), /수동 판매완료 정산이 이미 존재/);
      assert.deepEqual(await settlement(2), before);
      assert.equal((await book(2)).price, 7000);
      assert.equal(await value('select box_cost_charged as result from shipments where id=79'), 5000);
    });

    await t.test('재고 갱신이 실패하면 먼저 생성한 정산도 함께 롤백', async () => {
      await db.exec(`create function test_reject_book_update() returns trigger language plpgsql as $$
        begin if new.id=18 then raise exception 'test inventory failure'; end if; return new; end; $$;
        create trigger test_reject before update on books for each row execute function test_reject_book_update();`);
      await assert.rejects(sold(18), /test inventory failure/);
      assert.equal(await settlement(18), undefined);
      assert.equal((await book(18)).status, 'on_sale');
    });

    await t.test('DB 제약으로 주문 없는 일반 정산 및 중복 수동 정산 차단', async () => {
      await assert.rejects(db.exec(`insert into settlements(book_id,sale_amount,fee_percent,scheduled_date) values(17,7000,45,current_date)`), /settlements_sale_source_check/);
      await assert.rejects(db.exec(`insert into settlements(book_id,sale_amount,fee_percent,scheduled_date,sale_source,manual_sold_at) values(1,7000,45,current_date,'manual_sale',now())`), /settlements_manual_sale_book_unique/);
    });

    await t.test('기존 구매확정 정산은 그대로 생성되고 수동 판매 건은 제외', async () => {
      await db.exec(`insert into order_items(id,order_id,book_id) values(3,1,17),(4,1,1);`);
      const result = await value('select create_settlements_for_order(1) as result');
      assert.equal(result.inserted_count, 2); // 원래 주문 교재11 + 신규17, 수동판매1 제외
      assert.equal((await settlement(17)).sale_source, 'order');
      assert.equal((await settlement(17)).net_amount, 3850);
      assert.equal(await value('select count(*)::int as result from settlements where book_id=1'), 1);
      assert.equal((await value('select create_settlements_for_order(1) as result')).inserted_count, 0);
      await db.exec("insert into order_return_cases values(1,'requested')");
      assert.equal((await value('select create_settlements_for_order(1) as result')).reason, 'refund_on_hold');
      await db.exec('delete from order_return_cases');
    });

    await t.test('어드민 목록·지급합계와 판매자 마이페이지에 주문 없는 정산 노출', async () => {
      const admin = await value("select list_admin_settlements(array['pending'],'테스트교재') as result");
      assert.equal(admin.rows.find(row => row.book_id === 7905).net_amount, 3850);
      const payouts = await value('select admin_list_settlement_payouts() as result');
      assert.ok(payouts);
      const mine = await value('select get_my_settlements() as result');
      const target = mine.rows.find(row => row.book_id === 7905);
      assert.equal(target.source, 'manual');
      assert.equal(target.net_amount, 3850);
      assert.ok(target.scheduled_date);
      assert.ok(target.sold_at);
      assert.equal(target.box_cost_deducted, 0);
      assert.equal(target.order_id, null);
      assert.ok(!mine.rows.some(row => row.book_id === 4 || row.book_id === 5));
      assert.equal(mine.summary.expected_amount, mine.rows.filter(row => row.status === 'pending').reduce((sum,row) => sum+row.net_amount,0));
      await db.exec("set app.test_admin='false'; set role authenticated");
      assert.equal(await value('select count(*)::int as result from settlements where seller_user_id is distinct from auth.uid()'), 0);
      assert.equal((await db.query("update settlements set status='completed' where book_id=7905 returning *")).rows.length, 0);
      await db.exec('reset role');
      assert.equal((await settlement(7905)).status, 'pending');
      await assert.rejects(value('select list_admin_settlements() as result'), /Admin access/);
      await db.exec("set app.test_admin='true'");
    });

    await t.test('기존 지급완료 RPC와 호환되며 완료 건 재호출은 다시 대기로 만들지 않음', async () => {
      const id = (await settlement(7905)).id;
      const result = await value('select admin_complete_settlements(array[$1]::bigint[], $2) as result', [id, 'TEST-ONLY']);
      assert.equal(result.updated_count, 1);
      assert.equal(result.settlements[0].order_id, null);
      assert.equal((await sold(7905)).settlement_status, 'completed');
      assert.equal((await settlement(7905)).transfer_reference, 'TEST-ONLY');
      assert.equal((await value('select admin_complete_settlements(array[$1]::bigint[]) as result',[id])).updated_count, 0);
      const orderId = (await settlement(17)).id;
      await db.exec('update orders set refund_requested_at=now() where id=1');
      await assert.rejects(value('select admin_complete_settlements(array[$1]::bigint[]) as result',[orderId]), /환불 신청/);
    });
  } finally {
    await db.close();
  }
});
