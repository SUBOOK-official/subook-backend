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
  // 후속 관리 기능은 실제 목록·상세 RPC와 함께 검증한다.
  const listingMigration = read('20260922180318_separate_product_listing_from_stock.sql');
  await db.exec(`
    alter table products add column status text default 'selling', add column ai_summary text;
    alter table books add column title text, add column subject text, add column brand text,
      add column book_type text, add column instructor_name text;
    create table site_promotions(placement text,is_enabled boolean,starts_at timestamptz,ends_at timestamptz);
  `);
  await db.exec(listingMigration.match(/CREATE OR REPLACE FUNCTION public\.get_public_store_product_detail\([\s\S]*?\$function\$\s*;/)[0]);
  await db.exec(read('20260930031759_banner_copy_cache.sql'));
  const oldBannerIds = (await list('recommended',12)).map(row=>row.id);
  const oldPopular = await list();
  await db.exec(read('20260930043206_curate_catalog_and_hero_products.sql'));
  assert.deepEqual(await list(),oldPopular,'popular order and catalog contents are unchanged');
  const newRecommended = await list('recommended');
  assert.deepEqual(newRecommended.slice(0,4).map(row=>row.id),[31,8,9,10],'public sold-out recommendation keeps its configured position');
  assert.deepEqual(await list('recommended',12,12),newRecommended.slice(12,24));
  assert.deepEqual((await scalar('select get_public_hero_products()')).map(row=>row.product.id),oldBannerIds,'existing banner candidates are preserved');
  await db.exec("update product_recommendations set sort_order=0 where product_id=9");
  assert.deepEqual((await list('recommended')).slice(0,2).map(row=>row.id),[9,31],'tied order follows product id as in admin');
  assert.deepEqual((await scalar('select get_public_hero_products()')).map(row=>row.product.id),oldBannerIds,'recommendation edits do not change banner order');
  await db.exec(`
    update product_hero_banners set is_enabled=false;
    insert into product_hero_banners(product_id,sort_order,headline,is_enabled) values(139,1,'수동 문구',true),(140,0,'',true),(1,0,'숨김',true);
  `);
  assert.deepEqual((await scalar('select get_public_hero_products()')).map(row=>row.product.id),[140,139]);
  assert.deepEqual((await db.query('select id from get_banner_copy_sources()')).rows.map(row=>row.id),[140],'AI sources follow visible banners without manual copy');
  await db.exec(`
    insert into product_hero_banners(product_id,is_enabled) select generate_series(100,119),true;
    insert into banner_copy_cache(product_id,source_hash,copy)
      select id,banner_copy_source_hash(p),'기존 문구' from products p where id between 100 and 112;
  `);
  assert.deepEqual((await db.query('select id from get_banner_copy_sources() limit 8')).rows.map(row=>row.id),[113,114,115,116,117,118,119,140],
    'uncached banners beyond the first 13 are not starved by the generation cap');
  await db.exec("update product_hero_banners set is_enabled=false");
  assert.deepEqual(await scalar('select get_public_hero_products()'),[],'no automatic refill when all banners are disabled');

  await db.exec(`insert into products(id,title,instructor_name,option) select id,'시대인재 서바이벌 모의고사','홍길동','시즌 2' from generate_series(141,1250) id`);
  await db.exec("set role authenticated; select set_config('test.admin','false',false)");
  await assert.rejects(db.exec("select admin_list_curated_products()"),/관리자 권한/);
  await assert.rejects(db.exec("insert into product_hero_banners(product_id) values(1000)"),/row-level security/);
  assert.equal((await db.query('update product_hero_banners set is_enabled=true returning product_id')).rows.length,0);
  await db.exec("select set_config('test.admin','true',false)");
  const pageIds=[];
  for(let offset=0;offset<1110;offset+=30){
    const found=await scalar('select admin_list_curated_products($1,30,$2)',['시대 인재 홍길동 시즌 2',offset]);
    assert.equal(found.total_count,1110);
    pageIds.push(...found.products.map(row=>row.id));
  }
  assert.equal(pageIds.length,1110); assert.equal(new Set(pageIds).size,1110);
  assert.equal((await scalar("select admin_list_curated_products('',30,0)")).total_count,1250);
  assert.equal((await scalar("select admin_list_curated_products('홍',30,0)")).total_count,1110);
  assert.equal((await scalar("select admin_list_curated_products('1250',30,0)")).products[0].id,1250);
  assert.equal((await scalar("select admin_list_curated_products('%',30,0)")).total_count,0,'wildcards are literal');
  const emptyPage=await scalar("select admin_list_curated_products('홍',30,9999)");
  assert.deepEqual(emptyPage.products,[]); assert.equal(emptyPage.total_count,1110);
  await db.exec('insert into product_hero_banners(product_id) values(1000)');
  await db.exec('reset role; set role anon');
  await assert.rejects(db.exec('select admin_list_curated_products()'),/permission denied/);
  assert.equal(await scalar('select count(*)::int from product_hero_banners'),0);
  await assert.rejects(db.exec('select * from get_banner_copy_sources()'),/permission denied/);
  assert.deepEqual(await scalar('select get_public_hero_products()'),[]);
  await db.exec('reset role');
  // 테마 문맥은 UI 메타데이터다. 다른 분류의 선정 교재도 원래 순서대로 보존한다.
  await db.query('update content_themes set is_enabled=true where id=$1', [themeId]);
  const themeBeforeContext = await scalar('select get_public_theme_page($1,48,0)', [themeId]);
  await db.exec(read('20261003154147_theme_filter_context.sql'));
  await db.query('update content_themes set description=$2, filter_context=$3 where id=$1',
    [themeId, '관 소개', { brands: '시대인재', years: '2027' }]);
  const themeAfterContext = await scalar('select get_public_theme_page($1,48,0)', [themeId]);
  assert.deepEqual(themeAfterContext.products, themeBeforeContext.products);
  assert.equal(themeAfterContext.total_count, themeBeforeContext.total_count);
  assert.deepEqual(themeAfterContext.theme.filter_context, { brands: '시대인재', years: '2027' });
  assert.equal(themeAfterContext.theme.description, '관 소개');
  for (const invalid of [{ brands: [] }, { subject: null }, { unknown: '값' }, [], { years: '' }]) {
    await assert.rejects(db.query('update content_themes set filter_context=$2 where id=$1', [themeId, invalid]), /check constraint/);
  }
  await db.exec('set role anon');
  assert.equal((await scalar('select get_public_theme_page($1)', [themeId])).theme.description, '관 소개');
  await assert.rejects(db.query('update content_themes set description=$2 where id=$1', [themeId, '변조']), /permission denied/);
  await db.exec("reset role; set role authenticated; select set_config('test.admin','false',false)");
  assert.equal((await db.query('update content_themes set description=$2 where id=$1 returning id', [themeId, '변조'])).rows.length, 0);
  await db.exec("select set_config('test.admin','true',false)");
  assert.equal((await db.query('update content_themes set description=$2 where id=$1 returning id', [themeId, '관리자 수정'])).rows.length, 1);
  await db.query('update content_themes set is_enabled=false where id=$1', [themeId]);
  assert.equal(await scalar('select get_public_theme_page($1)', [themeId]), null);
  await db.exec('reset role');
  console.log('PASS: sold-out/tied recommendation order, independent banner selection/copy, no automatic refill, literal multi-field search, complete 1110-match pagination, anon/member/admin permissions');
  console.log('PASS: theme context preserves curated products/pagination, rejects malformed metadata, public read/admin-only writes, disabled themes stay private');
  console.log('PASS: unchanged catalog, server ranking/pagination, year/search/instructor filters, 8 available banners, 100+ product themes, missing/hidden/duplicate products, anon/member/admin RLS, private helper privilege, stale write conflict');
} finally { await db.close(); }
