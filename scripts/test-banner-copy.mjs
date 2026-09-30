import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
const scalar = async (sql, args) => Object.values((await db.query(sql, args)).rows[0])[0];
const token1 = '00000000-0000-4000-8000-000000000001';
const token2 = '00000000-0000-4000-8000-000000000002';
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create table products(id bigint primary key,title text,subject text,brand text,book_type text,ai_summary text,
      price int default 10000,is_listed boolean default true,rank int default 0);
    insert into products(id,title,ai_summary,rank) select n,'교재 '||n,'기존 설명',n from generate_series(1,15) n;
    create function list_public_store_products(p_sort text default 'recommended',p_limit int default 13,p_offset int default 0)
      returns table(id bigint) language sql stable as $$select id from public.products where is_listed order by rank limit p_limit offset p_offset$$;
  `);
  await db.exec(readFileSync(new URL('../supabase/migrations/20260930031759_banner_copy_cache.sql',import.meta.url),'utf8'));
  const hash = () => scalar('select banner_copy_source_hash(p) from products p where id=1');
  const claim = (h,t=token1) => scalar('select claim_banner_copy(1,$1,$2)',[h,t]);
  const finish = (h,t=token1,copy='매일 다지는 국어 실전') => scalar('select finish_banner_copy(1,$1,$2,$3)',[h,t,copy]);
  const copies = () => scalar('select get_public_banner_copies()');
  const h1 = await hash();
  assert.equal((await db.query('select * from get_banner_copy_sources()')).rows.length,13);
  assert.deepEqual(await Promise.all([claim(h1),claim(h1,token2)]),[true,false],'overlapping workers acquire only one lease');
  assert.equal(await finish(h1,token2),false,'foreign token cannot overwrite');
  assert.equal(await finish(h1),true);
  assert.equal(await claim(h1),false,'unchanged source is free on subsequent runs');
  assert.equal((await copies())[0].copy,'매일 다지는 국어 실전');
  await db.exec('update products set price=20000 where id=1');
  assert.equal(await hash(),h1,'price does not invalidate copy');
  await db.exec("update products set ai_summary='수정된 설명' where id=1");
  const h2=await hash();
  assert.deepEqual(await copies(),[],'changed source never exposes stale cached copy');
  assert.equal(await claim(h1),false,'old snapshot cannot claim');
  assert.equal(await claim(h2),true);
  await db.exec("update products set title='생성 중 교재명 변경' where id=1");
  assert.equal(await finish(h2),false,'edit during generation rejects stale result');
  const h3=await hash();
  assert.equal(await claim(h3),true,'stale generation releases cooldown for new source');
  await db.exec('update banner_copy_cache set lease_token=null,locked_until=null where product_id=1');
  assert.equal(await claim(h3),false,'failure cooldown prevents paid repeated requests');
  await db.exec("update banner_copy_cache set next_attempt_at=now()-interval '1 second' where product_id=1");
  assert.equal(await claim(h3),true);
  await assert.rejects(finish(h3,token1,'가'.repeat(21)),/check constraint/);
  assert.equal(await finish(h3),true);
  await db.exec('update products set is_listed=false where id=1');
  assert.deepEqual(await copies(),[],'hidden product not exposed');
  await db.exec('update products set is_listed=true,rank=99 where id=1');
  assert.deepEqual(await copies(),[],'product outside current top13 not exposed');
  await db.exec('update products set rank=1 where id=1');
  for (const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    assert.equal((await copies()).length,1);
    await assert.rejects(db.query('select * from banner_copy_cache'),/permission denied/);
    await assert.rejects(db.query('select * from get_banner_copy_sources()'),/permission denied/);
    await assert.rejects(claim(h3),/permission denied/);
    await assert.rejects(finish(h3),/permission denied/);
    await db.exec('reset role');
  }
  assert.equal(await scalar("select relrowsecurity from pg_class where oid='banner_copy_cache'::regclass"),true);
  console.log('PASS: private cache/RLS, public visibility/top13, atomic leases, unchanged/price reuse, source edits during generation, stale-token rejection, retry cooldown, length validation');
} finally { await db.close(); }
