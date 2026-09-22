// 실제 migration과 기존 포인트 적립/회수 함수를 격리 PostgreSQL에서 검증한다.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
const read = name => readFileSync(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8');
const original = read('20260902080505_unified_reviews.sql');
const points = read('20260902111905_member_points.sql');
const functionSql = (source, name) => {
  const match = source.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`, 'i'));
  assert.ok(match, name);
  return match[0];
};
const uid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const asUser = async n => db.query("select set_config('request.jwt.claim.sub',$1,false)", [n == null ? '' : uid(n)]);
const order = async (id, user, status = 'delivered', subtotal = 10000) => {
  await db.query('insert into orders(id,user_id,status) values ($1,$2,$3)', [id,uid(user),status]);
  await db.query("insert into order_items(order_id,product_id,title,total_price,quantity) values ($1,1,'검증 교재',$2,1)", [id,subtotal]);
};
const review = async (id, user, photo = false) => (await db.query(
  'select create_review($1,4,$2,$3::text[]) as result',
  [id,'교재 상태와 배송이 좋아서 만족합니다.', photo ? [`https://test.supabase.co/storage/v1/object/public/review-images/${uid(user)}/${id}/test.jpg`] : []]
)).rows[0].result;
const scalar = async sql => Object.values((await db.query(sql)).rows[0])[0];
try {
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create function public.is_admin_user() returns boolean language sql stable as $$select false$$;
    create function public.assert_member_not_blocked() returns void language plpgsql as $$begin
      if current_setting('test.blocked',true)='true' then raise exception 'blocked'; end if;
    end$$;
    create table products(id bigint primary key);
    insert into products values(1);
    create table orders(id bigint primary key,user_id uuid references auth.users(id),status text);
    create table order_items(id bigint generated always as identity primary key,order_id bigint references orders(id),
      product_id bigint,title text,total_price integer,quantity integer,refunded_at timestamptz);
  `);
  await db.exec(original.slice(original.indexOf('create table public.reviews ('), original.indexOf('comment on table public.reviews')));
  await db.exec(points.slice(points.indexOf('create table if not exists public.point_lots'), points.indexOf('alter table public.orders add column')));
  for (const name of ['normalize_review_input', 'get_my_reviews']) await db.exec(functionSql(original,name));
  for (const name of ['grant_points', 'get_point_balance', 'reclaim_review_points']) await db.exec(functionSql(points,name));
  await db.exec(read('20260922194215_review_activation_first_reward.sql'));
  for (let n=1; n<=8; n++) await db.query('insert into auth.users values ($1)',[uid(n)]);

  await asUser(1);
  await order(1,1);
  assert.equal((await review(1,1)).earned_points,1000);
  assert.equal(await scalar('select status from orders where id=1'),'delivered');
  assert.equal(await scalar(`select get_point_balance('${uid(1)}')`),1000);
  const firstId = await scalar('select id from reviews where order_id=1');
  assert.equal(await scalar(`select count(*)::integer from point_transactions where review_id=${firstId} and amount=1000 and kind='review_earn'`),1);
  await assert.rejects(review(1,1),/이미 후기를 작성/);
  assert.equal(await scalar('select count(*)::integer from point_transactions'),1);
  await order(2,1,'confirmed');
  assert.equal((await review(2,1)).earned_points,500);
  await order(3,1);
  assert.equal((await review(3,1,true)).earned_points,1000);

  await asUser(2);
  await order(4,2);
  const photoFirst = await review(4,2,true);
  assert.equal(photoFirst.earned_points,1500);
  assert.equal(photoFirst.first_review,true);
  await db.query('select reclaim_review_points($1,$2)',[photoFirst.id,'주문 전액 환불']);
  assert.equal(await scalar(`select get_point_balance('${uid(2)}')`),0);
  await db.query('update reviews set is_hidden=true where id=$1',[photoFirst.id]);
  await order(5,2);
  assert.equal((await review(5,2)).earned_points,500);

  await asUser(3);
  await order(6,3,'delivered',9999);
  assert.equal((await review(6,3)).earned_points,0);
  await order(7,3);
  assert.equal((await review(7,3)).earned_points,500);
  await order(8,3,'shipping');
  await assert.rejects(review(8,3),/배송완료 후/);
  await order(9,4);
  await assert.rejects(review(9,3),/주문을 찾을 수/);
  await order(10,3,'delivered',9999);
  await db.exec("insert into order_items(order_id,product_id,title,total_price,quantity,refunded_at) values(10,1,'환불 교재',10000,1,now())");
  assert.equal((await review(10,3)).earned_points,0);
  await order(11,3);
  await db.exec('update order_items set refunded_at=now() where order_id=11');
  await assert.rejects(review(11,3),/환불된 주문/);

  await asUser(4);
  await db.exec("select set_config('test.blocked','true',false)");
  await assert.rejects(review(9,4),/blocked/);
  await db.exec("select set_config('test.blocked','false',false)");
  await asUser(null);
  await assert.rejects(review(9,4),/Authentication required/);
  await asUser(4);
  await assert.rejects(db.query('select create_review(9,5,$1,$2::text[])',['짧음',[]]),/10자 이상/);
  await assert.rejects(db.query('select create_review(9,5,$1,$2::text[])',['입력 검증을 위한 충분한 길이의 후기',[`https://test.supabase.co/storage/v1/object/public/review-images/${uid(3)}/other.jpg`]]),/사진/);
  assert.equal(await scalar('select count(*)::integer from reviews where order_id=9'),0);
  assert.equal((await review(9,4)).earned_points,1000);
  assert.equal(await scalar("select has_function_privilege('anon','public.create_review(bigint,integer,text,text[])','execute')"),false);
  assert.equal(await scalar("select has_function_privilege('authenticated','public.create_review(bigint,integer,text,text[])','execute')"),true);
  const mine = await scalar('select get_my_reviews()');
  assert.equal(mine.length,1);
  assert.equal(mine[0].order_id,9);
  console.log('PASS: first/regular text/photo rewards, delivered without confirmation, ledger, duplicate, refund/hidden, subtotal, ownership, auth, validation, and privileges');
} finally { await db.close(); }
