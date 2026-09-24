// 운영 DB 접속 없이 실제 목록 RPC와 연도 migration을 PostgreSQL에서 실행한다.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const readMigration = (name) => readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), "utf8");
const source = readMigration("20260922180318_separate_product_listing_from_stock.sql");
const listFunction = source.match(/CREATE OR REPLACE FUNCTION public\.list_public_store_products\([\s\S]*?\$function\$\s*;/)[0];
const migration = readMigration("20260924185336_storefront_other_year_filter.sql");
const db = new PGlite();
try {
  await db.exec(`
    create function extract_chosung(text) returns text language sql immutable as 'select $1';
    create function similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function word_similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function storefront_condition_grade_rank(text) returns integer language sql immutable as 'select 1';
    create table products(id bigint primary key, title text default '테스트', option text,
      subject text default '국어', brand text default '시대인재', book_type text default '모의고사',
      published_year integer, instructor_name text, cover_image_url text,
      search_text text default '테스트', search_chosung text, is_listed boolean default true);
    create table books(id bigint primary key, product_id bigint references products(id),
      condition_grade text default 'S', price integer default 10000, original_price integer default 20000,
      cover_image_url text, inspection_image_urls text[], writing_percentage integer default 0,
      has_damage boolean default false, inspection_notes text, inspected_at timestamptz default now(),
      created_at timestamptz default now(), status text default 'on_sale', is_public boolean default true,
      option text, published_year integer);
    create table orders(id bigint,status text,payment_status text,paid_at timestamptz,pg_approved_at timestamptz);
    create table order_items(product_id bigint,order_id bigint,quantity integer,refunded_at timestamptz);
    create table wishlist_items(product_id bigint);
    insert into products(id,published_year) values (1,2027),(2,2026),(3,2025),(4,2024),(5,2023),(6,null),(7,2028),(8,2024),(9,2024),(10,2024);
    insert into books(id,product_id,published_year) select id,id,published_year from products;
    update products set is_listed=false where id=8;
    update books set is_public=false where id=9;
    update books set status='reserved',is_public=false where id=10;
    update products set brand='전일학원' where id=10;
  `);
  await db.exec(listFunction);
  const list = async (years = null, extra = "") => (await db.query(
    `select * from list_public_store_products(p_years=>$1::integer[],p_limit=>500 ${extra})`, [years],
  )).rows;
  const baseline = await list();
  const baseline2026 = await list([2026]);
  await db.exec(migration);
  assert.deepEqual(await list(), baseline);
  assert.deepEqual(await list([]), baseline);
  assert.deepEqual(await list([2026]), baseline2026);
  const ids = (rows) => rows.map((row) => row.id).sort((a, b) => a - b);
  assert.deepEqual(ids(await list([2027])), [1]);
  assert.deepEqual(ids(await list([2025])), [3]);
  assert.deepEqual(ids(await list([0])), [4, 5, 6, 7, 10]);
  assert.deepEqual(ids(await list([2026, 0])), [2, 4, 5, 6, 7, 10]);
  assert.deepEqual(await list([2027, 2026, 2025, 0]), baseline);
  assert.deepEqual(ids(await list([0], ",p_brands=>array['시대인재']")), [4, 5, 6, 7]);
  assert.deepEqual(ids(await list([0], ",p_search=>'2027'")), []);
  assert.deepEqual(ids(await list([2024])), [4, 10]);
  const others = await list([0]);
  const page = (await db.query("select * from list_public_store_products(p_years=>array[0],p_limit=>2,p_offset=>2)")).rows;
  assert.deepEqual(page, others.slice(2, 4));
  assert.ok(page.every((row) => row.total_count === 5));
  assert.equal(others.find((row) => row.id === 10).available_option_count, 0);
  await assert.rejects(db.exec(migration), /Expected exactly one storefront year predicate/);
  console.log("PASS: exact/other/mixed/NULL/future years, empty filters, hidden/sold-out visibility, search/brand combination, count/pagination, unchanged baseline, migration drift guard (15 assertions)");
} finally {
  await db.close();
}
