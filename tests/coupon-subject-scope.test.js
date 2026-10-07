import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = (name) => readFileSync(new URL(`../supabase/migrations/${name}.sql`, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
const functionSql = (source, name) => {
  const start = source.toLowerCase().indexOf(`create or replace function public.${name}(`);
  assert.ok(start >= 0, name);
  const body = source.slice(start);
  const tag = body.match(/\bas\s+(\$[a-z_]*\$)/i)[1];
  return body.slice(0, body.indexOf(`${tag};`, body.indexOf(tag) + tag.length) + tag.length + 1);
};
const points = migration('20260902111905_member_points');
const brand = migration('20260830123954_jeonil_brand_and_coupon_scope');
const patch = migration('20261007043026_coupon_subject_scope');
const user = '00000000-0000-4000-8000-000000000001';

test('쿠폰 과목 제한: 관리자 저장부터 주문 검증·카드 견적까지', async (t) => {
  const db = new PGlite();
  const call = async (sql, args = []) => (await db.query(sql, args)).rows[0].result;
  const create = (extra = {}) => call('select public.admin_create_coupon($1::jsonb) as result', [JSON.stringify({ title: '테스트', discount_type: 'fixed', discount_value: 15000, issuance_type: 'admin_assigned', ...extra })]);
  const update = (id, extra) => call('select public.admin_update_coupon($1,$2::jsonb) as result', [id, JSON.stringify(extra)]);
  const issue = async (id) => (await db.query('insert into member_coupons(coupon_id,user_id) values ($1,$2) returning id', [id, user])).rows[0].id;
  const list = (subtotal = 40000, ids = [1,2,3]) => call('select get_applicable_coupons($1,$2::bigint[]) as result', [subtotal, ids]);
  const quote = (id, ids = [1,2,3], extra = '') => call(`select create_order_core('${user}', $1::bigint[], $2::integer[], '테스트', '01000000000', '06200', '테스트 주소', '', '', p_member_coupon_id=>$3, p_validate_only=>true ${extra}) as result`, [ids, ids.map(() => 1), id]);
  const permissions = () => db.query(`select proname, proacl::text, prosecdef, proconfig from pg_proc where pronamespace='public'::regnamespace and proname in ('admin_create_coupon','admin_update_coupon','get_member_coupons','get_applicable_coupons','create_order_core') order by proname`);
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create table auth.users(id uuid primary key);
      insert into auth.users values ('${user}');
      create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid',true),'')::uuid $$;
      create function public.is_admin_user() returns boolean language sql stable as $$ select coalesce(current_setting('test.admin',true),'false')::boolean $$;
      create function public.assert_member_not_blocked() returns void language plpgsql as $$ begin end $$;
      create function public.get_remote_area_surcharge(text) returns integer language sql as $$ select 0 $$;
      create function public.get_point_balance(uuid) returns integer language sql as $$ select 10000 $$;
      create function public.consume_points_for_order(uuid,bigint,integer) returns void language plpgsql as $$ begin end $$;
      create sequence order_number;
      create function public.generate_order_number() returns text language sql as $$ select 'TEST-' || nextval('order_number') $$;
      create function public.generate_guest_order_number() returns text language sql as $$ select 'GUEST-' || nextval('order_number') $$;
      create table member_profiles(user_id uuid, is_blocked boolean, phone text);
      create table products(id bigint, cover_image_url text);
      create table books(id bigint primary key, brand text, subject text, price integer, status text default 'on_sale', is_public boolean default true,
        product_id bigint, title text, option text, condition_grade text, cover_image_url text);
      insert into books(id,brand,subject,price) values (1,'시대인재','수학',12000),(2,'시대인재','국어',18000),(3,'EBS','수학',10000);
      create table orders(id bigserial primary key,user_id uuid,order_number text,status text,shipping_recipient_name text,
        shipping_recipient_phone text,shipping_postal_code text,shipping_address_line1 text,shipping_address_line2 text,shipping_memo text,
        payment_method text,payment_status text,subtotal integer,shipping_fee integer,discount_amount integer,total_amount integer,item_count integer,
        auto_confirm_at timestamptz,applied_member_coupon_id bigint,coupon_discount_amount integer,refund_bank_name text,
        refund_account_number text,refund_account_holder text,guest_terms_agreed_at timestamptz,points_used integer);
      create table order_items(order_id bigint,book_id bigint,product_id bigint,title text,option_label text,condition_grade text,
        cover_image_url text,quantity integer,unit_price integer,total_price integer,refunded_at timestamptz);
      create table cart_items(user_id uuid,book_id bigint);
      create table pg_checkout_sessions(id bigserial primary key,order_number text,user_id uuid,payload jsonb,expected_amount integer,
        status text default 'created',order_id bigint,created_at timestamptz default now(),updated_at timestamptz default now());
      select set_config('test.uid','${user}',false), set_config('test.admin','true',false);
    `);
    await db.exec(migration('2026050601_add_coupons_admin_crud'));
    await db.exec(migration('2026050602_add_member_coupons_issuance'));
    await db.exec('alter table coupons add column budget_cap_amount integer, add column valid_days integer, add column issue_on_signup boolean default false, add column scope_brand text');
    for (const name of ['admin_create_coupon','admin_update_coupon','get_applicable_coupons']) await db.exec(functionSql(brand, name));
    for (const name of ['point_policy','create_order_core','create_order','create_pg_checkout_session','finalize_pg_checkout_session']) await db.exec(functionSql(points, name));
    await db.exec(migration('20260929033735_fix_refunded_inventory_reservation'));
    await db.exec("revoke all on function public.create_order_core(uuid,bigint[],integer[],text,text,text,text,text,text,text,bigint,text,text,text,text,boolean,boolean,integer) from public,anon,authenticated");
    const before = (await permissions()).rows;
    await db.exec(patch);

    await t.test('권한·RLS 유지, 비관리자 저장 거부', async () => {
      assert.deepEqual((await permissions()).rows, before);
      assert.deepEqual((await db.query("select relrowsecurity from pg_class where oid in ('coupons'::regclass,'member_coupons'::regclass)")).rows.map((r) => r.relrowsecurity), [true,true]);
      await db.exec("select set_config('test.admin','false',false)");
      await assert.rejects(create({ scope_subject:'수학' }), /Admin access required/);
      await db.exec("select set_config('test.admin','true',false)");
    });
    const { coupon_id: id } = await create({ scope_subject:'수학' });
    const memberId = await issue(id);
    await t.test('과목만 제한, 혼합 주문의 대상 합계와 정액 상한', async () => {
      assert.equal((await list())[0].eligible_subtotal,22000);
      assert.equal((await list())[0].scope_subject,'수학');
      assert.equal((await quote(memberId)).coupon_discount_amount,15000);
      assert.equal((await quote(memberId,[1])).coupon_discount_amount,12000);
      assert.deepEqual(await list(18000,[2]),[]);
      await assert.rejects(quote(memberId,[2]), /수학 교재에만/);
      assert.deepEqual(await list(40000,null),[]);
    });
    await t.test('브랜드·과목 교집합과 대상 금액 최소 조건', async () => {
      await update(id,{scope_brand:'시대인재', min_order_amount:15000});
      assert.deepEqual(await list(),[]);
      await assert.rejects(quote(memberId), /최소 주문 금액/);
      await update(id,{min_order_amount:12000});
      assert.equal((await list())[0].eligible_subtotal,12000);
      assert.equal((await quote(memberId)).coupon_discount_amount,12000);
      await assert.rejects(quote(memberId,[2,3]), /시대인재 · 수학 교재에만/);
    });
    await t.test('정률은 대상 소계 기준, 상한 유지', async () => {
      await update(id,{discount_type:'percentage',discount_value:15,max_discount_amount:5000});
      assert.equal((await quote(memberId)).coupon_discount_amount,1800);
      await update(id,{max_discount_amount:1000});
      assert.equal((await quote(memberId)).coupon_discount_amount,1000);
      await assert.rejects(update(id,{max_discount_amount:null}), /할인 상한/);
    });
    await t.test('지정값 수정·미전달 보존·제한 해제·기존 쿠폰 호환', async () => {
      await update(id,{scope_subject:'국어'});
      assert.equal((await list())[0].eligible_subtotal,18000);
      await update(id,{title:'제목만 수정'});
      assert.equal((await list())[0].scope_subject,'국어');
      await update(id,{scope_subject:null});
      assert.equal((await list())[0].eligible_subtotal,30000);
      await update(id,{scope_brand:null});
      assert.equal((await list(40000,null))[0].eligible_subtotal,40000);
      await assert.rejects(update(id,{scope_subject:'물리학'}), /coupons_scope_subject_check/);
      await update(id,{scope_subject:'  수학  ',scope_brand:'시대인재',discount_type:'fixed',discount_value:3000});
      const wallet = await call("select get_member_coupons('available') as result");
      assert.equal(wallet[0].scope_subject,'수학');
      assert.equal(wallet[0].scope_brand,'시대인재');
    });
    await t.test('만료·비활성·다른 회원·사용 한도 제한 유지', async () => {
      await update(id,{is_active:false});
      assert.deepEqual(await list(),[]);
      await assert.rejects(quote(memberId),/비활성/);
      await update(id,{is_active:true});
      await db.exec(`update member_coupons set expires_at=now()-interval '1 day' where id=${memberId}`);
      assert.deepEqual(await list(),[]);
      await assert.rejects(quote(memberId),/만료/);
      await db.exec(`update member_coupons set expires_at=null where id=${memberId}; select set_config('test.uid','00000000-0000-4000-8000-000000000002',false)`);
      assert.deepEqual(await list(),[]);
      await db.exec(`select set_config('test.uid','${user}',false)`);
      await issue(id);
      await db.exec(`update member_coupons set status='used' where id<>${memberId}`);
      await update(id,{usage_limit_per_user:1});
      assert.deepEqual(await list(),[]);
      await assert.rejects(quote(memberId),/사용 한도/);
      await update(id,{usage_limit_per_user:null});
    });
    await t.test('무료배송도 제한 검사, 포인트 병용 금액 일치', async () => {
      await update(id,{discount_type:'free_shipping',discount_value:0});
      assert.equal((await quote(memberId)).total_amount,40000);
      await assert.rejects(quote(memberId,[2]),/교재에만/);
      await update(id,{discount_type:'fixed',discount_value:3000});
      assert.equal((await quote(memberId,[1,2,3],', p_points_amount=>2000')).total_amount,38000);
    });
    await t.test('카드 세션과 무통장 실제 주문도 동일한 제한 금액 사용', async () => {
      const args = [[1,2,3],[1,1,1],memberId];
      const session = await call("select create_pg_checkout_session($1::bigint[],$2::integer[],'테스트','01000000000','06200','주소','','',p_member_coupon_id=>$3) as result",args);
      assert.equal(session.total_amount,40000);
      assert.equal((await db.query('select count(*)::int as n from orders')).rows[0].n,0);
      await db.exec('begin; savepoint card_path');
      const finalized = await call('select finalize_pg_checkout_session($1,$2) as result',[session.order_number,session.total_amount]);
      assert.equal(finalized.success,true);
      assert.equal(finalized.total_amount,40000);
      const replay = await call('select finalize_pg_checkout_session($1,$2) as result',[session.order_number,session.total_amount]);
      assert.equal(replay.already_completed,true);
      await db.exec('rollback to card_path; commit');
      await update(id,{scope_subject:'과학'});
      await assert.rejects(call('select finalize_pg_checkout_session($1,$2) as result',[session.order_number,session.total_amount]),/교재에만/);
      await update(id,{scope_subject:'수학'});
      const order = await call("select create_order($1::bigint[],$2::integer[],'테스트','01000000000','06200','주소','','',p_member_coupon_id=>$3) as result",args);
      assert.equal(order.total_amount,session.total_amount);
      assert.equal((await db.query('select coupon_discount_amount from orders')).rows[0].coupon_discount_amount,3000);
      assert.equal((await db.query('select count(*)::int as n from order_items')).rows[0].n,3);
    });
  } finally { await db.close(); }
});
