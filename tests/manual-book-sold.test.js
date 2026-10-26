import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const read = (name) => readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8');
const functionSql = (file, name) => {
  const match = read(file).match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?AS (\\$[a-z_]*\\$)[\\s\\S]*?\\1\\s*;`, 'i'));
  assert.ok(match, name);
  return match[0];
};

test('수동 판매완료: 관리자 권한·주문 보호·권별 재고·변경 이력', async (t) => {
  const db = new PGlite();
  const row = async (id) => (await db.query('select status,is_public,price from books where id=$1', [id])).rows[0];
  const sold = async (id) => (await db.query('select admin_mark_book_sold($1) as result', [id])).rows[0].result;
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$select '00000000-0000-0000-0000-000000000001'::uuid$$;
      create function is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('app.test_admin',true),'true')='true'$$;
      create function storefront_condition_grade_rank(text) returns integer language sql immutable as 'select 1';
      create table products(id bigint primary key, title text default '교재', option text, subject text, brand text,
        book_type text,published_year integer,instructor_name text,cover_image_url text,
        status text default 'selling',is_listed boolean default true,updated_at timestamptz default now());
      create table books(id bigint primary key,product_id bigint references products(id),title text default '교재',
        option text,subject text,brand text,book_type text,published_year integer,instructor_name text,cover_image_url text,
        condition_grade text default 'S',price integer default 7000,status text default 'on_sale',is_public boolean default true,
        created_at timestamptz default now());
      create table orders(id bigint primary key,status text);
      create table order_items(id bigint primary key,order_id bigint references orders(id),book_id bigint references books(id),refunded_at timestamptz);
      create table book_change_logs(book_id bigint,changed_by uuid,field text,old_value text,new_value text);
      insert into products(id) values(1),(2);
      insert into products(id,is_listed,status) values(3,false,'hidden');
      insert into books(id,product_id) values (1,1),(2,1),(3,2),(4,2),(5,2),(6,2),(7,2),(8,2),(9,2),(10,2);
      insert into books(id,product_id,is_public) values(11,3,false);
      update books set status='reserved',is_public=false where id=3;
      update books set status='discarded',is_public=false where id=4;
      update books set condition_grade='DISCARD',is_public=false where id=10;
      insert into orders values(1,'pending'),(2,'confirmed'),(3,'cancelled'),(4,'refunded'),(5,'preparing');
      insert into order_items values(1,1,5,null),(2,2,6,null),(3,3,7,null),(4,4,8,null),(5,5,9,now());
    `);
    await db.exec(functionSql('20260922180318_separate_product_listing_from_stock.sql', 'refresh_storefront_product_status'));
    await db.exec(functionSql('20260922180318_separate_product_listing_from_stock.sql', 'products_enforce_derived_status'));
    await db.exec(functionSql('2026040709_z_add_products_storefront.sql', 'books_refresh_storefront_product_status'));
    await db.exec(functionSql('2026051309_book_change_logs.sql', 'books_log_changes'));
    await db.exec(`
      create trigger books_refresh after update on books for each row execute function books_refresh_storefront_product_status();
      create trigger products_derive before update on products for each row execute function products_enforce_derived_status();
      create trigger books_audit before update on books for each row execute function books_log_changes();
    `);
    await db.exec(read('20261026023957_admin_mark_book_sold.sql'));

    await t.test('일반 회원 및 익명 실행 차단', async () => {
      const permissions = (await db.query("select has_function_privilege('anon','admin_mark_book_sold(bigint)','execute') as anon, has_function_privilege('authenticated','admin_mark_book_sold(bigint)','execute') as member")).rows[0];
      assert.deepEqual(permissions, { anon: false, member: true });
      await db.exec("set app.test_admin='false'");
      await assert.rejects(sold(1), /관리자만/);
      assert.equal((await row(1)).status, 'on_sale');
      await db.exec("set app.test_admin='true'");
    });

    await t.test('판매한 한 권만 내리고 가격·다른 재고·관리자 변경 이력을 보존', async () => {
      const sibling = await row(2);
      assert.deepEqual(await sold(1), { book_id: 1, already_sold: false });
      assert.deepEqual(await row(1), { status: 'settled', is_public: false, price: 7000 });
      assert.deepEqual(await row(2), sibling);
      assert.equal((await db.query('select status from products where id=1')).rows[0].status, 'selling');
      assert.deepEqual((await db.query("select field,new_value,changed_by from book_change_logs where book_id=1 order by field")).rows, [
        { field: 'is_public', new_value: 'false', changed_by: '00000000-0000-0000-0000-000000000001' },
        { field: 'status', new_value: 'settled', changed_by: '00000000-0000-0000-0000-000000000001' },
      ]);
    });

    await t.test('중복 요청은 상태와 이력을 추가 변경하지 않음', async () => {
      assert.deepEqual(await sold(1), { book_id: 1, already_sold: true });
      assert.equal((await db.query('select count(*)::integer as n from book_change_logs where book_id=1')).rows[0].n, 2);
    });

    await t.test('마지막 재고 소진 시 상품 품절 자동 반영', async () => {
      await sold(2);
      assert.equal((await db.query('select status from products where id=1')).rows[0].status, 'sold_out');
    });

    await t.test('예약·폐기·폐기등급·없는 교재를 거부', async () => {
      for (const id of [3,4,10]) {
        const before = await row(id);
        await assert.rejects(sold(id), /판매중인 교재만/);
        assert.deepEqual(await row(id), before);
      }
      await assert.rejects(sold(999), /찾을 수 없습니다/);
      await assert.rejects(sold(null), /찾을 수 없습니다/);
    });

    await t.test('입금대기 및 구매확정 주문이 연결된 판매중 재고를 보호', async () => {
      for (const id of [5,6]) {
        await assert.rejects(sold(id), /진행 중인 주문/);
        assert.equal((await row(id)).status, 'on_sale');
      }
    });

    await t.test('취소·전액환불·품목환불 이력은 새 수동 판매를 막지 않음', async () => {
      const orders = (await db.query('select * from orders order by id')).rows;
      const items = (await db.query('select * from order_items order by id')).rows;
      for (const id of [7,8,9]) assert.equal((await sold(id)).already_sold, false);
      assert.deepEqual((await db.query('select * from orders order by id')).rows, orders);
      assert.deepEqual((await db.query('select * from order_items order by id')).rows, items);
    });

    await t.test('숨김 상품은 판매완료 처리 후에도 숨김 유지', async () => {
      await sold(11);
      assert.equal((await db.query('select status from products where id=3')).rows[0].status, 'hidden');
    });
  } finally {
    await db.close();
  }
});
