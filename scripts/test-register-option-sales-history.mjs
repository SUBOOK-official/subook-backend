// 격리된 PostgreSQL(PGlite)에서 실행. 운영 DB 접속/변경 없음.
// npm exec --package=@electric-sql/pglite 등으로 설치 후 PGLITE_MODULE에 진입 파일 URL 지정 가능.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const sql = (path) => readFileSync(new URL('../supabase/' + path, import.meta.url), 'utf8');
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create function auth.role() returns text language sql as $$ select current_setting('request.jwt.claim.role',true) $$;
    create table admin_users(user_id uuid);
    create table products(id bigint primary key, title text, option text, subject text, brand text, book_type text,
      published_year integer, instructor_name text, cover_image_url text, search_text text);
    create table books(id bigint primary key, product_id bigint, option text, status text, price integer,
      original_price integer, condition_grade text default 'S', created_at timestamptz default now(), inspection_image_urls text[]);
    create table orders(id bigint primary key, payment_status text, status text, paid_at timestamptz, created_at timestamptz default now());
    create table order_items(id bigint primary key, order_id bigint, book_id bigint, product_id bigint, option_label text,
      unit_price integer, condition_grade text default 'S', refunded_at timestamptz);
    create table manual_settlements(id bigint primary key, book_id bigint, sale_amount integer, status text, sold_at date, created_at timestamptz default now());
  `);
  const adminFn = sql('migrations/2026051301_lockdown_rls_and_admin.sql').match(/create or replace function public\.is_admin_user\(\)[\s\S]*?\$\$;/i)[0];
  await db.exec(adminFn);
  await db.exec(sql('migrations/20260908123723_register_option_sales_history.sql'));
  await db.exec(`
    select set_config('request.jwt.claim.role','service_role',false);
    insert into products(id,title,published_year,subject) values
      (1,'2025 메가스터디 Quel 모의고사 수학',2025,'수학'),
      (2,'2027 기본 교재 수학',2027,'수학'), (3,'2026 빈 교재 수학',2026,'수학');
    insert into books(id,product_id,option,status,price,original_price,created_at) values
      (1,1,'2회','reserved',9900,10000,'2026-09-01'),
      (2,1,'3회','reserved',3000,10000,'2026-09-01'),
      (3,1,'4회','reserved',3000,10000,'2026-09-01'),
      (4,1,'5회','settled',9000,null,'2026-09-01'),
      (5,1,'6회','settled',6000,null,'2026-09-01'),
      (6,1,'7회','on_sale',7000,10000,'2026-09-01'),
      (7,1,'7회','on_sale',7500,10000,'2026-09-01'),
      (8,1,'7회','reserved',8000,10000,'2026-09-01'),
      (9,1,'2회','settled',8000,10000,'2026-08-01'),
      (10,2,null,'on_sale',1000,null,'2026-09-01'),
      (11,2,'  ','settled',2000,null,'2026-09-01');
    insert into orders(id,payment_status,status,paid_at) values
      (1,'paid','shipping','2026-09-07T12:17:54Z'),
      (2,'paid','confirmed','2026-08-01T12:00:00Z'),
      (3,'paid','cancelled','2026-09-08T00:00:00Z'),
      (4,'pending','paid','2026-09-08T00:00:00Z'),
      (5,'paid','paid','2026-09-08T00:00:00Z');
    insert into order_items(id,order_id,book_id,product_id,option_label,unit_price,condition_grade,refunded_at) values
      (1,1,1,1,'2회',3000,'S',null), (2,1,2,1,'3회',3000,'S',null), (3,1,3,1,'4회',3000,'S',null),
      (4,2,9,1,'2회',2500,'A+',null), (5,3,1,1,'2회',99999,'S',null),
      (6,4,1,1,'2회',99999,'S',null), (7,5,1,1,'2회',99999,'S',now()),
      (8,2,null,1,'과거 옵션',4000,'A',null), (9,2,8,1,'7회',6500,'S',null);
    insert into manual_settlements values
      (1,4,4500,'paid','2026-09-02',now()), (2,9,8800,'paid','2026-09-03',now()),
      (3,5,99999,'cancelled','2026-09-04',now());
  `);
  const search = async (value, limit = 20, offset = 0) => (await db.query('select admin_search_products_for_register($1,$2,$3) result', [value,limit,offset])).rows[0].result;
  const [product] = await search('Quel 수학');
  const byOption = Object.fromEntries(product.options.map((o) => [o.option, o]));
  assert.equal(product.inventory_count, 2);
  assert.equal(product.representative_original_price, 10000);
  assert.deepEqual(['2회','3회','4회'].map((key) => byOption[key].stock_count), [0,0,0]);
  assert.equal(byOption['2회'].price, 3000, '주문 스냅샷 가격, 현재 books.price 아님');
  assert.equal(byOption['2회'].last_sold_grade, 'S');
  assert.equal(byOption['2회'].sales_count, 2, '환불/취소/미결제 및 수동 중복 제외');
  assert.equal(byOption['2회'].sales_min_price, 2500);
  assert.equal(byOption['2회'].sales_max_price, 3000);
  assert.equal(new Date(byOption['2회'].last_sold_at).toISOString(), '2026-09-07T12:17:54.000Z');
  assert.equal(byOption['5회'].price, 4500, '수동 실제 판매가');
  assert.equal(byOption['6회'].price, 6000, '실제 기록 없는 이전 등록가');
  assert.equal(byOption['6회'].last_sold_price, null);
  assert.equal(byOption['6회'].sales_count, 0);
  assert.equal(byOption['6회'].original_price, null);
  assert.equal(byOption['7회'].price, 7000, '현재 최저가 우선');
  assert.equal(byOption['7회'].stock_count, 2);
  assert.equal(byOption['7회'].last_sold_price, 6500);
  assert.equal(byOption['과거 옵션'].stock_count, 0, '재고 원본 없는 주문 옵션도 보존');
  assert.equal(byOption['과거 옵션'].last_sold_price, 4000);
  const [basic] = await search('기본');
  assert.equal(basic.options.length, 1, 'null/빈 옵션 합침');
  assert.equal(basic.options[0].option, null);
  assert.equal(basic.options[0].stock_count, 1);
  assert.deepEqual((await search('빈 교재'))[0].options, []);
  assert.deepEqual(await search('   '), []);
  assert.deepEqual(await search('Quel 국어'), []);
  assert.deepEqual((await search('수학',1,1)).map((p) => p.id), [3], '연도 정렬/페이지 유지');
  await db.exec("select set_config('request.jwt.claim.role','authenticated',false)");
  await assert.rejects(search('Quel'), /Admin access required/);
  await db.exec("select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false); insert into admin_users values ('00000000-0000-4000-8000-000000000001')");
  assert.equal((await search('Quel')).length, 1);
  const grants = (await db.query("select has_function_privilege('anon','admin_search_products_for_register(text,integer,integer)','EXECUTE') anon, has_function_privilege('authenticated','admin_search_products_for_register(text,integer,integer)','EXECUTE') authenticated")).rows[0];
  assert.deepEqual(grants, {anon: false, authenticated: true});
  console.log('PASS: 품절/기본/주문 전용 옵션, 판매가·이전 등록가, 환불·취소·미결제·중복 제외, 재고 수량, 검색·페이지, 관리자 권한');
} finally {
  await db.close();
}
