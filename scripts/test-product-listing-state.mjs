// PostgreSQL에서 실제 migration/트리거/RPC를 실행한다. 운영 DB에는 접속하지 않는다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
const read = name => readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8');
const functionSql = (file, name) => {
  const source = read(file);
  const match = source.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`, 'i'));
  assert.ok(match, name);
  return match[0];
};
const row = async id => (await db.query('select status,is_listed from products where id=$1', [id])).rows[0];
const visibility = async (id, value) => (await db.query('select admin_bulk_set_products_visibility(array[$1::bigint],$2::boolean) as result', [id,value])).rows[0].result;
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$select null::uuid$$;
    create function is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('app.test_admin',true),'true')='true'$$;
    create function extract_chosung(text) returns text language sql immutable as 'select $1';
    create function similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function word_similarity(text,text) returns real language sql immutable as 'select 0::real';
    create function storefront_condition_grade_rank(text) returns integer language sql immutable as 'select 1';
    create table products(id bigint primary key,group_key text,title text default '테스트',option text,subject text default '국어',
      brand text default '시대인재',book_type text default '모의고사',published_year integer default 2027,
      instructor_name text,cover_image_url text,search_text text default '테스트',search_chosung text,
      status text default 'selling',created_at timestamptz default now(),updated_at timestamptz default now());
    create table books(id bigint primary key,product_id bigint references products(id),title text default '테스트',
      option text,subject text default '국어',brand text default '시대인재',book_type text default '모의고사',
      published_year integer default 2027,instructor_name text,condition_grade text default 'S',price integer default 10000,
      original_price integer default 20000,cover_image_url text default 'cover.jpg',inspection_image_urls text[],
      writing_percentage integer default 0,has_damage boolean default false,inspection_notes text,
      inspected_at timestamptz default now(),created_at timestamptz default now(),status text default 'on_sale',
      is_public boolean default true,serial_number integer,location text);
    create table product_status_logs(id bigint generated always as identity primary key,product_id bigint,changed_by uuid,
      old_status text,new_status text,changed_at timestamptz default now());
    create table book_change_logs(id bigint generated always as identity primary key,book_id bigint,field text,
      old_value text,new_value text,changed_at timestamptz default now());
    create table orders(id bigint,status text,payment_status text,paid_at timestamptz,pg_approved_at timestamptz);
    create table order_items(product_id bigint,order_id bigint,quantity integer,refunded_at timestamptz);
    create table wishlist_items(product_id bigint);
    create table direct_sale_products(product_id bigint);
    create function _admin_inventory_book_flags() returns table(product_id bigint,missing_location boolean,
      picking_pending boolean,missing_serial boolean,missing_detail_photo boolean,missing_price boolean,
      hidden_on_sale boolean,is_on_sale boolean) language sql as $$
      select product_id,false,false,false,false,false,false,status='on_sale' from books$$;
    insert into products(id,status) values (1,'selling'),(2,'hidden'),(3,'hidden'),(4,'hidden'),(5,'hidden'),(6,'hidden'),(7,'selling');
    update products set brand='전일학원' where id in (2,7);
    insert into books(id,product_id,status,is_public) values
      (1,1,'on_sale',true),(2,2,'reserved',false),(3,3,'settled',false),
      (4,4,'on_sale',false),(6,6,'discarded',false),(7,7,'on_sale',true);
    -- 2: 판매 소진 확정. 3: 판매 이력이 있어도 직접 숨긴 정황이면 보수적으로 유지.
    insert into product_status_logs(product_id,old_status,new_status,changed_at) values
      (2,'selling','hidden','2026-09-20'),(3,'selling','hidden','2026-09-20');
    insert into book_change_logs(book_id,field,old_value,new_value,changed_at) values
      (2,'status','on_sale','reserved','2026-09-20'),(2,'is_public','true','false','2026-09-20'),
      (3,'is_public','true','false','2026-09-20');
    alter table products enable row level security;
    create policy products_select_public on products for select to anon,authenticated using(true);
    create policy products_update_admin on products for update to authenticated using(is_admin_user()) with check(is_admin_user());
    grant select on products to anon,authenticated;
    grant update on products to authenticated;
  `);
  await db.exec(functionSql('2026040709_z_add_products_storefront.sql','books_refresh_storefront_product_status'));
  await db.exec(`create trigger books_refresh_storefront_product_status_trigger after insert or update or delete on books
    for each row execute function books_refresh_storefront_product_status();`);
  // 이전 정의의 상태 이력 기록을 그대로 붙여 보존 여부를 검증한다.
  await db.exec(functionSql('20260731191823_product_status_history.sql','products_log_status_change'));
  await db.exec(`create trigger products_log_status_change_trigger after update on products
    for each row execute function products_log_status_change();`);

  await db.exec(read('20260921070327_jeonil_sold_out_storefront.sql'));
  const beforeBooks=(await db.query('select * from books order by id')).rows;
  const beforePublic=(await db.query("select * from list_public_store_products(p_sort=>'price_low')")).rows;
  const beforeSearch=(await db.query("select * from search_storefront_products('테스트')")).rows;
  await db.exec(read('20260922180318_separate_product_listing_from_stock.sql'));
  assert.deepEqual((await db.query('select * from books order by id')).rows,beforeBooks);
  assert.deepEqual((await db.query("select * from list_public_store_products(p_sort=>'price_low')")).rows,beforePublic);
  assert.deepEqual((await db.query("select * from search_storefront_products('테스트')")).rows,beforeSearch);
  await db.exec(`create trigger books_enforce_public_storefront_rules_trigger before insert or update on books
    for each row execute function books_enforce_public_storefront_rules();`);
  assert.deepEqual(await row(1),{status:'selling',is_listed:true});
  assert.deepEqual(await row(2),{status:'sold_out',is_listed:true});
  for(const id of [3,4,5,6]) assert.deepEqual(await row(id),{status:'hidden',is_listed:false});
  console.log('PASS: 판매 소진 이력만 이관, 수동 숨김·이력 불명·빈 상품·폐기 보존');

  await db.exec("update books set status='reserved' where id=1");
  assert.deepEqual(await row(1),{status:'sold_out',is_listed:true});
  assert.equal((await db.query('select is_public from books where id=1')).rows[0].is_public,false);
  await db.exec("update books set status='on_sale',is_public=true where id=1");
  assert.deepEqual(await row(1),{status:'selling',is_listed:true});
  await db.exec("update books set status='settled' where id=1");
  assert.equal((await row(1)).status,'sold_out');
  await db.exec('insert into books(id,product_id) values(10,1)');
  assert.equal((await row(1)).status,'selling');
  await visibility(1,false);
  assert.deepEqual(await row(1),{status:'hidden',is_listed:false});
  await db.exec("insert into books(id,product_id) values(11,1); update books set status='on_sale',is_public=true where id=1;");
  assert.equal((await row(1)).status,'hidden');
  assert.equal((await db.query('select count(*)::int as n from books where product_id=1 and is_public')).rows[0].n,0);
  await assert.rejects(db.query('select admin_set_book_visibility(11,true)'),/상품을 먼저 공개/);
  await visibility(1,true);
  assert.equal((await row(1)).status,'selling');
  assert.equal((await db.query('select count(*)::int as n from books where product_id=1 and is_public')).rows[0].n,3);
  console.log('PASS: 마지막 예약·판매→품절, 취소·재입고→판매중, 명시적 숨김은 취소·재입고에도 유지');

  const list = async () => (await db.query("select * from list_public_store_products(p_search=>'테스트')")).rows;
  const detail = async id => (await db.query('select * from get_public_store_product_detail($1)',[id])).rows;
  const search = async () => (await db.query("select * from search_storefront_products('테스트')")).rows;
  assert.ok((await list()).some(r=>Number(r.product_id)===2));
  assert.equal((await detail(2))[0].available_option_count,0);
  assert.equal((await search()).find(r=>Number(r.id)===2).status,'sold_out');
  const hideSold = await visibility(2,false);
  assert.equal(hideSold.updated_products,1);
  assert.equal(hideSold.updated_books,0);
  assert.deepEqual(await detail(2),[]);
  assert.ok(!(await list()).some(r=>Number(r.product_id)===2));
  assert.ok(!(await search()).some(r=>Number(r.id)===2));
  const showSold = await visibility(2,true);
  assert.deepEqual(showSold.skipped_product_ids,[]);
  assert.equal((await row(2)).status,'sold_out');
  assert.equal((await detail(2))[0].available_option_count,0);
  await visibility(3,true);
  assert.equal((await row(3)).status,'sold_out');
  assert.deepEqual(await detail(3),[]);
  assert.ok(!(await list()).some(r=>Number(r.product_id)===3));
  assert.ok(!(await search()).some(r=>Number(r.id)===3));
  console.log('PASS: 전일 품절 목록·상세·자동완성 유지, 전일 수동 숨김 적용, 일반 품절 노출 차단');

  // SQL 직접 변경·상품 생성·권별 숨김·재공개와 기존 옵션 균일성 가드.
  await db.exec("update products set status='selling' where id=2");
  assert.equal((await row(2)).status,'sold_out');
  await db.exec('update products set is_listed=false where id=7');
  assert.equal((await db.query('select is_public from books where id=7')).rows[0].is_public,false);
  await db.exec("insert into products(id,status) values(20,'hidden'),(21,'selling'); insert into books(id,product_id) values(20,20),(21,21);");
  assert.equal((await row(20)).status,'hidden');
  assert.equal((await row(21)).status,'selling');
  await db.query('select admin_set_book_visibility(21,false)');
  assert.equal((await row(21)).status,'sold_out');
  await db.query('select admin_set_book_visibility(21,true)');
  assert.equal((await row(21)).status,'selling');
  await db.exec("update books set option='1회' where id=1; update books set option='2회' where id=10; update products set option='상품옵션' where id=1; update books set price=15000 where id=11;");
  assert.equal((await db.query('select option from products where id=1')).rows[0].option,'상품옵션');
  await db.exec("insert into products(id) values(22); insert into books(id,product_id,price,is_public) values(22,22,null,false);");
  assert.deepEqual((await visibility(22,true)).skipped_product_ids,[22]);
  const adminList=(await db.query("select admin_list_products_with_inventory(p_status=>'sold_out',p_search=>'테스트',p_limit=>1,p_offset=>0) as result")).rows[0].result;
  assert.equal(adminList.items.length,1);
  assert.ok(adminList.total_count>=2);
  assert.equal(adminList.items[0].is_listed,true);
  assert.ok('issues' in adminList.items[0] && 'is_direct_sale' in adminList.items[0]);
  console.log('PASS: 직접 상태 덮어쓰기 차단, 숨김 등록, 권별 노출, 옵션 보존, 미완성 재고 안내, 관리자 필터·건수');

  // 상품 로그가 없던 구형 판매 소진: 최신 책 공개 변경이 판매와 동시인 경우 복원.
  await db.exec(`
    insert into products(id,status) values(100,'hidden'),(101,'hidden'),(102,'hidden'),(103,'hidden');
    insert into books(id,product_id,status,is_public) values
      (100,100,'settled',false),(101,101,'settled',false),(102,102,'settled',false),(103,103,'on_sale',false);
    delete from product_status_logs where product_id between 100 and 103;
    insert into book_change_logs(book_id,field,old_value,new_value,changed_at)
      select id,'status','on_sale','settled','2026-07-19'::timestamptz from books where id between 100 and 103;
    insert into book_change_logs(book_id,field,old_value,new_value,changed_at)
      select id,'is_public','true','false','2026-07-19'::timestamptz from books where id between 100 and 103;
    insert into product_status_logs(product_id,old_status,new_status,changed_at)
      values(101,'sold_out','hidden','2026-08-01');
    insert into book_change_logs(book_id,field,old_value,new_value,changed_at)
      values(102,'is_public','true','false','2026-08-01');
  `);
  const correction=read('20260922194000_restore_legacy_sold_out_listing.sql');
  const unchangedBooks=(await db.query('select * from books order by id')).rows;
  const unchangedPublic=await list();
  await db.exec(correction);
  assert.deepEqual(await row(100),{status:'sold_out',is_listed:true});
  for(const id of [101,102,103]) assert.deepEqual(await row(id),{status:'hidden',is_listed:false});
  assert.deepEqual((await db.query('select * from books order by id')).rows,unchangedBooks);
  assert.deepEqual(await list(),unchangedPublic);
  await visibility(100,false);
  await db.exec(correction);
  assert.deepEqual(await row(100),{status:'hidden',is_listed:false});
  console.log('PASS: 상품 로그 없는 판매 소진 복원, 후속 수동 숨김·미판매 재고 보존, 책·구매자 목록 불변, 재실행 안전');

  // 식스샵 이전처럼 두 로그가 모두 없고 전량 판매완료인 상품도 품절로 분류한다.
  await db.exec(`
    insert into products(id,status,created_at) select id,'hidden','2026-05-06'::timestamptz from generate_series(200,207) id;
    insert into books(id,product_id,status,is_public) values
      (200,200,'settled',false),(201,200,'settled',false),
      (202,202,'discarded',false),(203,203,'settled',false),(204,203,'on_sale',false),
      (205,204,'settled',false),(206,205,'settled',false),(207,206,'settled',false),(208,207,'settled',false);
    update products set updated_at='2026-08-20' where id between 200 and 207;
    delete from product_status_logs where product_id between 200 and 207;
    insert into product_status_logs(product_id,old_status,new_status,changed_at)
      values(204,'sold_out','hidden','2026-08-01');
    insert into book_change_logs(book_id,field,old_value,new_value,changed_at)
      values(206,'is_public','true','false','2026-08-01');
    update products set updated_at='2026-09-23 00:00:00+00' where id=206;
    update products set created_at='2026-08-01' where id=207;
  `);
  const importCorrection=read('20260922194100_restore_imported_sold_out_products.sql');
  const importedBooks=(await db.query('select * from books order by id')).rows;
  const importedPublic=await list();
  const importedSearch=await search();
  await db.exec(importCorrection);
  assert.deepEqual(await row(200),{status:'sold_out',is_listed:true});
  for(const id of [201,202,203,204,205,206,207]) assert.deepEqual(await row(id),{status:'hidden',is_listed:false},`legacy exclusion ${id}`);
  assert.deepEqual((await db.query('select * from books order by id')).rows,importedBooks);
  assert.deepEqual(await list(),importedPublic);
  assert.deepEqual(await search(),importedSearch);
  assert.deepEqual(await detail(200),[]);
  await db.exec(importCorrection);
  assert.equal((await db.query("select count(*)::int as n from product_status_logs where product_id=200 and new_status='sold_out'")).rows[0].n,1);
  await visibility(200,false);
  await db.exec(importCorrection);
  assert.deepEqual(await row(200),{status:'hidden',is_listed:false});
  console.log('PASS: 이전 데이터 전량 판매완료 복원, 빈 상품·폐기·미판매·명시적 숨김·후속 수정 보존, 구매자 목록/검색 불변');

  await db.exec("set app.test_admin='false'");
  await assert.rejects(visibility(1,false),/Admin access required/);
  await assert.rejects(db.query('select admin_set_book_visibility(1,false)'),/Admin access required/);
  await assert.rejects(db.query('select admin_list_products_with_inventory()'),/Admin access required/);
  await db.exec('set role authenticated; update products set is_listed=false where id=1; reset role;');
  assert.equal((await row(1)).is_listed,true);
  assert.ok((await db.query("select count(*)::int as n from product_status_logs where product_id=1 and new_status='sold_out'")).rows[0].n>0);
  console.log('PASS: 비관리자 RPC·직접 UPDATE 차단, 기존 상태 이력 기록 유지');
} finally {
  await db.close();
}
