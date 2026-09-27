// 실제 migration/RPC를 격리 PostgreSQL에서 검증한다. 운영 데이터 변경 없음.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const read = name => readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8');
const base = read('20260922180318_separate_product_listing_from_stock.sql')
  .match(/CREATE OR REPLACE FUNCTION public\.list_public_store_products\([\s\S]*?\$function\$\s*;/)[0];
const db = new PGlite();
const scalar = async (sql, args) => Object.values((await db.query(sql, args)).rows[0])[0];
const themeId = '00000000-0000-4000-8000-000000000001';
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create function is_admin_user() returns boolean language sql stable as $$select current_setting('test.admin',true)='true'$$;
    create function extract_chosung(text) returns text language sql immutable as 'select $1';
    create function similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function word_similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function storefront_condition_grade_rank(text) returns integer language sql immutable as 'select 1';
    create table products(id bigint primary key, title text default '테스트', option text,
      subject text default '국어', brand text default '시대인재', book_type text default '모의고사',
      published_year integer default 2027, instructor_name text default '강사', cover_image_url text,
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
    insert into products(id) select generate_series(1,140);
    insert into books(id,product_id) select id,id from products;
    update products set is_listed=false where id=1;
    update books set status='reserved',is_public=false where id between 2 and 8;
    update products set brand='전일학원' where id=8;
    update products set published_year=2024 where id=35;
    update books set price=id*1000;
  `);
  await db.exec(base);
  await db.exec(read('20260924185336_storefront_other_year_filter.sql'));
  const list = async (sort='popular', limit=500, offset=0) => (await db.query('select * from list_public_store_products(p_sort=>$1,p_limit=>$2,p_offset=>$3)',[sort,limit,offset])).rows;
  const before = await list();
  await db.exec(read('20260927192942_curated_recommendations_and_themes.sql'));
  assert.deepEqual(await list(), before);
  assert.deepEqual(await list('recommended'), before, 'empty recommendations preserve popular order');
  await db.exec(`
    insert into product_recommendations(product_id,sort_order,is_enabled,headline)
      select id,id,true,'추천' from products where id<=20;
    insert into product_recommendations(product_id,sort_order,is_enabled) values(31,0,true),(32,0,false);
  `);
  assert.deepEqual(await list(), before, 'popular ranking is unaffected');
  const recommended = await list('recommended');
  assert.equal(recommended[0].id,31);
  assert.deepEqual(await list('recommended',12,12),recommended.slice(12,24));
  assert.equal(new Set(recommended.map(row=>row.id)).size,recommended.length);
  assert.ok(recommended.every(row=>row.total_count===before.length));
  assert.equal((await db.query("select * from list_public_store_products(p_sort=>'recommended',p_years=>array[0])")).rows[0].id,35);
  assert.equal((await db.query("select * from list_public_store_products(p_sort=>'recommended',p_instructors=>array['다른 강사'])")).rows.length,0);
  assert.equal((await db.query("select * from list_public_store_products(p_sort=>'recommended',p_search=>'2026')")).rows.length,0);
  const banners = await scalar('select get_public_recommendation_banners()');
  assert.equal(banners.length,8);
  assert.deepEqual(banners.map(row=>row.product.id),[31,9,10,11,12,13,14,15], 'filter availability before taking eight');
  await db.query('insert into content_themes(id,title,image_url,product_ids,is_enabled) values($1,$2,$3,$4,true)', [themeId,'테스트 테마','https://example.com/icon.webp',[1,99999,31,31,8,...Array.from({length:132},(_,i)=>i+9)]]);
  const page = await scalar('select get_public_theme_page($1,24,0)', [themeId]);
  assert.equal(page.products.length,24);
  assert.equal(page.products[0].id,31);
  assert.equal(page.total_count,132);
  const second = await scalar('select get_public_theme_page($1,24,24)', [themeId]);
  assert.equal(second.products.length,24);
  assert.ok(second.products.every(row=>!page.products.some(first=>first.id===row.id)));
  assert.equal((await scalar('select get_public_theme_page($1,24,10000)',[themeId])).products.length,0);
  assert.equal(await scalar("select get_public_theme_page('00000000-0000-4000-8000-000000000002')"),null);
  await db.exec('set role anon');
  assert.equal(await scalar('select count(*)::int from product_recommendations where not is_enabled'),0);
  await assert.rejects(db.exec("insert into product_recommendations(product_id) values(40)"),/permission denied/);
  await assert.rejects(db.exec('select * from curated_product_cards(array[31]::bigint[])'),/permission denied/);
  assert.equal((await scalar('select get_public_recommendation_banners()')).length,8);
  await db.exec("reset role; set role authenticated; select set_config('test.admin','false',false)");
  await assert.rejects(db.exec("insert into product_recommendations(product_id) values(40)"),/row-level security/);
  assert.equal((await db.query('update product_recommendations set sort_order=500 returning product_id')).rows.length,0);
  await db.exec("select set_config('test.admin','true',false)");
  await db.exec("insert into product_recommendations(product_id) values(40)");
  const timestamp = await scalar('select updated_at from product_recommendations where product_id=40');
  await db.exec('update product_recommendations set headline=\'수정\' where product_id=40');
  assert.notEqual(await scalar('select updated_at from product_recommendations where product_id=40'),timestamp);
  assert.equal((await db.query("update product_recommendations set headline='덮어쓰기' where product_id=40 and updated_at=$1 returning product_id",[timestamp])).rows.length,0);
  await db.query('update content_themes set is_enabled=false where id=$1',[themeId]);
  assert.equal(await scalar('select get_public_theme_page($1)',[themeId]),null,'public RPC never exposes disabled themes, even to admin');
  await db.exec('reset role');
  console.log('PASS: unchanged catalog, server ranking/pagination, year/search/instructor filters, 8 available banners, 100+ product themes, missing/hidden/duplicate products, anon/member/admin RLS, private helper privilege, stale write conflict');
} finally { await db.close(); }
