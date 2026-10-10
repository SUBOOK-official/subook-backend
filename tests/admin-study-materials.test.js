import { before, after, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const id = "10000000-0000-4000-8000-000000000001";
const user = "20000000-0000-4000-8000-000000000001";
const q = async (sql, params = []) => (await db.query(sql, params)).rows;
const register = (size = 100) => q("select * from admin_register_study_material($1,'수학','대수','교재','교재.pdf',$2)", [id, size]);
before(async () => {
  await db.exec(`create role anon; create role authenticated; create role service_role;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key); insert into auth.users values('${user}');
    create function auth.uid() returns uuid language sql stable as $$select '${user}'::uuid$$;
    create function is_admin_user() returns boolean language sql stable as $$select coalesce(current_setting('app.admin',true)='true',false)$$;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb);
    alter table storage.objects enable row level security;
    grant usage on schema public,auth,storage to anon,authenticated;
    grant select,insert on storage.objects to anon,authenticated;
  `);
  await db.exec(await readFile(new URL('../supabase/migrations/20261010063147_admin_study_materials_2028.sql',import.meta.url),'utf8'));
});
after(() => db.close());

test('익명·일반 회원은 목록, 업로드, 등록 접근 불가', async () => {
  await db.exec('set role anon');
  await assert.rejects(q('select * from admin_study_materials'), /permission denied/);
  await assert.rejects(register(), /permission denied/);
  assert.deepEqual(await q("select * from storage.objects where bucket_id='admin-study-materials'"), []);
  await db.exec("set role authenticated; select set_config('app.admin','false',false)");
  assert.deepEqual(await q('select * from admin_study_materials'), []);
  await assert.rejects(register(), /관리자 권한/);
  await assert.rejects(q("insert into storage.objects(bucket_id,name) values('admin-study-materials',$1)",[`2028/${id}.pdf`]), /row-level security/);
});

test('관리자도 업로드 완료와 파일 크기 일치 없이 등록 불가', async () => {
  await db.exec("set role authenticated; select set_config('app.admin','true',false)");
  await assert.rejects(register(), /업로드가 완료되지/);
  await assert.rejects(q("insert into storage.objects(bucket_id,name) values('admin-study-materials','invalid.txt')"), /row-level security/);
  await q("insert into storage.objects(bucket_id,name,metadata) values('admin-study-materials',$1,$2)", [`2028/${id}.pdf`, JSON.stringify({size:100,mimetype:'application/pdf'})]);
  await assert.rejects(register(101), /업로드가 완료되지/);
  const rows = await register(); assert.equal(rows[0].uploaded_by,user); assert.equal(rows[0].subject_detail,'대수');
  await register(); assert.equal((await q('select * from admin_study_materials')).length,1);
  await assert.rejects(q("select admin_register_study_material($1,'영어','','다른교재','교재.pdf',100)",[id]), /일치하지/);
});

test('다른 관리자도 자료 열람 가능, 일반 회원은 등록된 자료도 볼 수 없음', async () => {
  await db.exec("reset role; create or replace function auth.uid() returns uuid language sql stable as $$select '30000000-0000-4000-8000-000000000001'::uuid$$; set role authenticated");
  assert.equal((await q('select * from admin_study_materials')).length,1);
  assert.equal((await q("select * from storage.objects where bucket_id='admin-study-materials'")).length,1);
  await db.exec("select set_config('app.admin','false',false)");
  assert.equal((await q('select * from admin_study_materials')).length,0);
  assert.equal((await q("select * from storage.objects where bucket_id='admin-study-materials'")).length,0);
  await db.exec('reset role');
  const [bucket] = await q("select * from storage.buckets where id='admin-study-materials'");
  assert.equal(bucket.public,false); assert.equal(Number(bucket.file_size_limit),1073741824); assert.deepEqual(bucket.allowed_mime_types,['application/pdf']);
});
