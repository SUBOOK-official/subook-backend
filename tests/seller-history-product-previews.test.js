import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
const migration = (name) => readFileSync(new URL(`../supabase/migrations/${name}.sql`, import.meta.url), 'utf8');
const baseline = migration('20260810094500_pickup_merge_boxcount_no_sum');
const functionSql = baseline.slice(baseline.indexOf('create or replace function public.get_my_pickup_requests'), baseline.indexOf('-- 2)'));
const userId = '00000000-0000-4000-8000-000000000001';
test('판매 이력 썸네일·상품 링크와 회원별 접근 경계', async (t) => {
  const db = new PGlite();
  const history = async (limit=20, offset=0) => (await db.query('select public.get_my_pickup_requests($1,$2) as result',[limit,offset])).rows[0].result;
  try {
    await db.exec(`
      create role authenticated; create schema auth;
      create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid',true),'')::uuid $$;
      create table pickup_requests(id bigint primary key,user_id uuid,merged_into_id bigint,request_number text,status text,
        item_count integer,box_count integer,expected_book_count integer,desired_pickup_date date,tracking_number text,
        tracking_carrier text,cj_tracking_status text,cj_tracking_status_code text,cj_tracking_last_checked_at timestamptz,
        created_at timestamptz,updated_at timestamptz);
      create table shipments(id bigint primary key,user_id uuid,pickup_request_id bigint,status text,box_count integer,pickup_date date,created_at timestamptz);
      create table books(id bigint primary key,shipment_id bigint,product_id bigint,title text,option text,condition_grade text,
        price integer,original_price integer,status text,discard_reason text,inspection_image_urls text[],inspection_notes text,
        inspected_at timestamptz,cover_image_url text,is_public boolean);
      create table products(id bigint primary key,cover_image_url text,is_listed boolean default true,brand text,book_type text);
      create table pickup_items(id bigint,pickup_request_id bigint,title text,subject text,brand text,book_type text,
        original_price integer,condition_memo text,is_manual_entry boolean,cover_photo_url text);
      insert into pickup_requests(id,user_id,request_number,status,created_at) values
        (1,'${userId}','MY-1','inspected','2026-10-07'), (2,'${userId}','MERGED','inspected','2026-10-06'),
        (3,'00000000-0000-4000-8000-000000000002','OTHER','inspected','2026-10-08'),
        (4,'${userId}','PENDING','pending','2026-10-04');
      update pickup_requests set merged_into_id=1 where id=2;
      insert into shipments(id,user_id,pickup_request_id,status,created_at) values
        (1,'${userId}',1,'inspected','2026-10-07'),(2,'${userId}',2,'inspected','2026-10-06'),
        (3,'${userId}',null,'inspected','2026-10-05'),(4,'00000000-0000-4000-8000-000000000002',3,'inspected','2026-10-08');
      insert into products(id,cover_image_url) values (10,'https://example.com/product.jpg'),(20,'https://example.com/private.jpg');
      insert into books(id,shipment_id,product_id,title,option,status,is_public,cover_image_url) values
        (11,1,10,'공개 교재','3회','on_sale',true,'https://example.com/book.jpg'),
        (12,2,10,'병합 교재','4회','settled',false,null),
        (13,3,20,'비공개 교재','5회','inspecting',false,null),
        (14,4,10,'다른 회원 교재','6회','on_sale',true,null);
      insert into pickup_items(id,pickup_request_id,title,cover_photo_url) values (21,4,'신청 교재','https://example.com/pickup.jpg');
      select set_config('test.uid','${userId}',false);
    `);
    await db.exec(functionSql);
    const acl = async () => (await db.query("select proacl::text as acl,prosecdef,proconfig from pg_proc where oid='public.get_my_pickup_requests(integer,integer)'::regprocedure")).rows[0];
    const beforeAcl = await acl();
    const beforeRows = await history();
    await db.exec(migration('20261007044715_seller_history_product_previews'));
    await t.test('필드만 추가하며 기존 이력·옵션·권한 보존', async () => {
      assert.deepEqual(await acl(),beforeAcl);
      const rows=await history();
      const withoutPreviews=rows.map(row=>({...row,items:row.items.map(({product_id,cover_image_url,...item})=>item)}));
      assert.deepEqual(withoutPreviews,beforeRows);
      assert.equal(rows.length,3);
      assert.equal(rows[0].items[0].product_id,10);
      assert.equal(rows[0].items[0].cover_image_url,'https://example.com/book.jpg');
      assert.equal(rows[0].items[1].product_id,10);
      assert.equal(rows[0].items[1].cover_image_url,'https://example.com/product.jpg');
      assert.equal(rows[1].items[0].product_id,null);
      assert.equal(rows[1].items[0].cover_image_url,'https://example.com/private.jpg');
      assert.equal(rows[2].items[0].cover_photo_url,'https://example.com/pickup.jpg');
      assert.deepEqual(await history(1,1),[rows[1]]);
    });
    await t.test('다른 회원의 수거 이력과 비로그인 접근 차단 유지', async () => {
      await db.exec("select set_config('test.uid','00000000-0000-4000-8000-000000000002',false)");
      assert.deepEqual((await history()).map(row=>row.id),[3]);
      await db.exec("select set_config('test.uid','',false)");
      await assert.rejects(history(),/Authentication required/);
    });
    await t.test('숨김·일반 품절은 링크 제외, 공개 전일학원 품절은 상세 정책과 일치', async () => {
      await db.exec(`select set_config('test.uid','${userId}',false); update products set is_listed=false where id=10;`);
      assert.equal((await history())[0].items[0].product_id,null);
      await db.exec("update products set is_listed=true where id=10; update books set status='settled' where product_id=10;");
      assert.equal((await history())[0].items[0].product_id,null);
      await db.exec("update products set brand='전일학원',book_type='모의고사' where id=10");
      assert.equal((await history())[0].items[0].product_id,10);
    });
  } finally { await db.close(); }
});
