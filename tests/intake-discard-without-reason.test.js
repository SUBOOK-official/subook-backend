import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = (name) => readFileSync(new URL(`../supabase/migrations/${name}.sql`, import.meta.url), 'utf8');
const baseline = migration('20260908101808_intake_discounts');
const functionSql = baseline.slice(baseline.indexOf('create or replace function'), baseline.indexOf('create or replace function public.admin_register_intake_batch'));
const patch = migration('20261007031659_optional_intake_discard_reason');

test('검수 폐기 사유 생략과 기존 등록 보호 조건', async (t) => {
  const db = new PGlite();
  const discard = { title: '검수 테스트 교재', condition_grade: 'DISCARD', is_public: true };
  const register = async (item = discard, key = '00000000-0000-4000-8000-000000000001') =>
    (await db.query('select public.admin_register_intake_book(1, $1::uuid, $2::jsonb) as result', [key, JSON.stringify(item)])).rows[0].result;
  const definition = async () => (await db.query(`select pg_get_functiondef(oid) as definition,
    proacl::text as acl, prosecdef, proconfig from pg_proc
    where oid='public.admin_register_intake_book(bigint,uuid,jsonb)'::regprocedure`)).rows[0];
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create function public.is_admin_user() returns boolean language sql stable
        as $$ select coalesce(current_setting('test.admin',true),'false')::boolean $$;
      create sequence book_serial;
      create function public._next_book_serial() returns integer language sql as $$ select nextval('book_serial')::integer $$;
      create table public.shipments (id bigint primary key);
      create table public.products (id bigserial primary key, group_key text unique, title text,
        subject text, subject_detail text, brand text, book_type text, published_year integer,
        instructor_name text, cover_image_url text, status text);
      create table public.books (id bigserial primary key, shipment_id bigint, product_id bigint, title text,
        option text, subject text, subject_detail text, brand text, book_type text, published_year integer,
        instructor_name text, original_price integer, price integer, condition_grade text,
        writing_percentage integer, has_damage boolean, inspection_notes text, inspected_at timestamptz,
        cover_image_url text, inspection_image_urls text[], is_public boolean, status text,
        serial_number integer unique, location text, discard_reason text, discount_type text, discount_value integer);
      create table public.admin_intake_receipts (request_key uuid primary key, shipment_id bigint, payload jsonb, result jsonb);
      insert into public.shipments values (1);
      insert into public.products (title) values ('기존 교재');
      insert into public.books (title,status,discard_reason) values ('과거 기록','discarded','과거 사유');
      select set_config('test.admin','true',false);
    `);
    await db.exec(functionSql);
    await db.exec(`revoke all on function public.admin_register_intake_book(bigint,uuid,jsonb) from public, anon;
      grant execute on function public.admin_register_intake_book(bigint,uuid,jsonb) to authenticated, service_role`);
    await t.test('기존 사유 필수 오류 재현', async () => {
      await assert.rejects(register(), /판매불가 사유를 입력하세요/);
    });
    const before = await definition();
    await db.exec(patch);
    await t.test('사유 필수 조건만 제거하고 관리자 권한·함수 설정 유지', async () => {
      const after = await definition();
      assert.deepEqual(after, { ...before, definition: before.definition.replace("    if nullif(btrim(p_item->>'discard_reason'),'') is null then raise exception '판매불가 사유를 입력하세요.'; end if;\n", '') });
      await db.exec('set role anon');
      await assert.rejects(register(), /permission denied/);
      await db.exec('reset role; set role authenticated');
      await db.exec("select set_config('test.admin','false',false)");
      await assert.rejects(register(), /Admin access required/);
      await db.exec("reset role; select set_config('test.admin','true',false)");
    });
    await t.test('사유·표지·가격 없이 폐기하고 비공개 재고로 등록', async () => {
      const result = await register();
      assert.equal(result.success, true);
      assert.equal(result.discarded, true);
      assert.deepEqual((await db.query('select status,is_public,price,discard_reason from public.books where id=$1', [result.book_id])).rows[0],
        { status: 'discarded', is_public: false, price: null, discard_reason: null });
      assert.equal((await register()).replayed, true);
      assert.equal((await db.query('select count(*)::int as n from public.books')).rows[0].n, 2);
      assert.equal((await db.query("select discard_reason from public.books where title='과거 기록'")).rows[0].discard_reason, '과거 사유');
      await assert.rejects(register({ ...discard, title: '변경한 요청' }), /이미 처리된 요청의 내용이 다릅니다/);
    });
    await t.test('판매용 검수의 가격·필기·위치 검증 유지', async () => {
      const key = '00000000-0000-4000-8000-000000000002';
      const item = { ...discard, condition_grade: 'S', product_id: 1, is_public: false };
      await assert.rejects(register(item, key), /판매가는 1원 이상/);
      item.price = 10000;
      await assert.rejects(register(item, key), /필기·손상·구성품 확인/);
      Object.assign(item, { writing_percentage: 0, has_damage: false, components_confirmed: true });
      await assert.rejects(register(item, key), /보관 위치/);
      item.location = 'A-1';
      const result = await register(item, key);
      assert.equal(result.discarded, false);
      assert.equal(result.price, 10000);
      assert.equal((await db.query('select status from public.books where id=$1', [result.book_id])).rows[0].status, 'on_sale');
    });
  } finally {
    await db.close();
  }
});
