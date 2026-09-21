// 실제 RPC 정의를 독립 PostgreSQL 메모리 DB에서 검증한다. 운영 데이터는 사용하지 않는다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
try {
  await db.exec(`
    create function extract_chosung(text) returns text language sql immutable as 'select $1';
    create function similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function word_similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function storefront_condition_grade_rank(text) returns integer language sql immutable as 'select 1';
    create table products(id bigint primary key, title text, option text, subject text default '국어',
      brand text default '전일학원', book_type text default '모의고사', published_year integer default 2027,
      instructor_name text, cover_image_url text, search_text text, search_chosung text, status text default 'hidden');
    create table books(id bigint primary key, product_id bigint, title text, option text, subject text,
      brand text, book_type text, published_year integer default 2027, instructor_name text,
      condition_grade text default 'S', price integer default 59000, original_price integer default 108000,
      cover_image_url text, inspection_image_urls text[], writing_percentage integer, has_damage boolean,
      inspection_notes text, inspected_at timestamptz, created_at timestamptz default now(), status text, is_public boolean);
    create table orders(id bigint primary key, status text, payment_status text, paid_at timestamptz, pg_approved_at timestamptz);
    create table order_items(product_id bigint,order_id bigint,quantity integer,refunded_at timestamptz);
    create table wishlist_items(product_id bigint);
    insert into products(id,title,search_text) select id,'FULL '||id,'full '||id from generate_series(1,9) id;
    update products set brand='시대인재' where id=5;
    update products set book_type='N제' where id=6;
    update products set status='selling' where id in (1,7);
    insert into books(id,product_id,status,is_public) values
      (1,1,'on_sale',true), (2,2,'reserved',false), (3,3,'settled',false),
      (4,4,'discarded',false), (5,5,'reserved',false), (6,6,'reserved',false),
      (7,7,'on_sale',true), (8,7,'reserved',false),
      (9,8,'on_sale',false), (10,8,'reserved',false), (11,9,'on_sale',false);
  `);
  await db.exec(readFileSync(new URL('../supabase/migrations/20260921070327_jeonil_sold_out_storefront.sql', import.meta.url), 'utf8'));
  const list = (await db.query("select * from list_public_store_products(p_sort=>'price_low')")).rows;
  assert.deepEqual(list.map(r=>Number(r.id)).sort(),[1,2,3,7]);
  assert.equal(list.find(r=>Number(r.id)===2).available_option_count,0);
  assert.equal(list.find(r=>Number(r.id)===7).available_option_count,1);
  assert.equal(list[0].total_count,4);
  const detail = async id => (await db.query('select * from get_public_store_product_detail($1)',[id])).rows;
  for (const id of [2,3]) {
    const [row] = await detail(id);
    assert.equal(row.price,59000);
    assert.equal(row.available_option_count,0);
    assert.equal(row.option_books.length,1);
    assert.equal(row.option_books[0].stock_count,0);
    assert.equal(row.option_books[0].status,'sold_out');
  }
  for (const id of [4,5,6,8,9]) assert.deepEqual(await detail(id),[],`상품 ${id}는 비공개 유지`);
  assert.equal((await detail(7))[0].available_option_count,1);
  const search = (await db.query("select * from search_storefront_products('full')")).rows;
  assert.deepEqual(search.map(r=>Number(r.id)).sort(),[1,2,3,7]);
  assert.equal(search.find(r=>Number(r.id)===2).status,'sold_out');
  assert.equal(search.find(r=>Number(r.id)===2).price,59000);
  assert.equal(search.find(r=>Number(r.id)===2).available_count,0);
  assert.equal((await db.query("select * from list_public_store_products(p_brands=>array['시대인재'])")).rows.length,0);
  assert.equal((await db.query("select * from list_public_store_products(p_search=>'2026')")).rows.length,0);
  assert.equal((await db.query("select * from list_public_store_products(p_instructors=>array['없는강사'])")).rows.length,0);
  const page = (await db.query('select * from list_public_store_products(p_limit=>1,p_offset=>1)')).rows;
  assert.equal(page.length,1);
  assert.equal(page[0].total_count,4);
  // 재입고 시 정상 판매 표시로 자동 복귀하고, 숨기면 판매 이력이 있어도 공개하지 않는다.
  await db.exec("update books set status='on_sale',is_public=true where id=2; update products set status='selling' where id=2;");
  assert.equal((await detail(2))[0].available_option_count,1);
  await db.exec("update books set is_public=false where id=2; update products set status='hidden' where id=2;");
  assert.deepEqual(await detail(2),[]);
  console.log('PASS: 전일 품절 목록·상세·자동완성, 가용수량, 재입고, 숨김·폐기·다른 브랜드/유형 제외, 필터·페이지네이션');
} finally {
  await db.close();
}
