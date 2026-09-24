import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

test('프로모션 migration과 RLS: 공개 예약 필터, 관리자 CRUD, 일반 회원 쓰기 차단', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role bypassrls;
      create schema auth; create schema storage;
      create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
      create function auth.role() returns text language sql stable as $$ select current_setting('request.jwt.claim.role', true) $$;
      create table public.admin_users (user_id uuid primary key);
      insert into public.admin_users values ('00000000-0000-0000-0000-000000000001');
      create function public.is_admin_user() returns boolean language sql stable security definer set search_path = public, auth as $$
        select coalesce(auth.role() = 'service_role', false) or exists(select 1 from public.admin_users where user_id = auth.uid());
      $$;
      create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
      create table storage.objects (id uuid default gen_random_uuid(), bucket_id text, name text);
      alter table storage.objects enable row level security;
      grant usage on schema public, storage, auth to anon, authenticated;
      grant select, insert, update, delete on storage.objects to anon, authenticated;
    `);
    await db.exec(readFileSync(new URL('../supabase/migrations/20260924165808_site_promotions.sql', import.meta.url), 'utf8'));
    await db.exec(`insert into public.site_promotions (title, placement, image_url, alt_text, is_enabled, starts_at, ends_at) values
      ('future', 'home_hero', '/test.webp', 'future', true, now() + interval '1 day', null),
      ('expired', 'home_popup', '/test.webp', 'expired', true, null, now() - interval '1 second');`);
    await db.exec('set role anon');
    const publicRows = (await db.query('select title, is_enabled, starts_at, ends_at from public.site_promotions')).rows;
    assert.ok(publicRows.length >= 3);
    assert.ok(publicRows.every((r) => r.is_enabled && !['future', 'expired', '대치동 현강 희귀 모의고사 (내림)'].includes(r.title)));
    const insert = "insert into public.site_promotions (title, placement, image_url, alt_text) values ('test', 'home_hero', '/test.webp', 'test')";
    await assert.rejects(db.exec(insert), /permission denied/);
    await db.exec("reset role; set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false)");
    await assert.rejects(db.exec(insert), /row-level security/);
    assert.equal((await db.query("update public.site_promotions set title = 'hacked' returning id")).rows.length, 0);
    assert.equal((await db.query('delete from public.site_promotions returning id')).rows.length, 0);
    await assert.rejects(db.exec("insert into storage.objects (bucket_id, name) values ('site-promotions', 'hacked.png')"), /row-level security/);
    await db.exec("select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false)");
    assert.equal((await db.query('select id from public.site_promotions')).rows.length, 7);
    await db.exec(insert);
    const updated = await db.query("update public.site_promotions set title = 'changed', updated_at = '2000-01-01' where title = 'test' returning updated_at");
    assert.equal(updated.rows.length, 1);
    assert.ok(Date.parse(updated.rows[0].updated_at) > Date.parse('2026-01-01'));
    assert.equal((await db.query("delete from public.site_promotions where title = 'changed' returning id")).rows.length, 1);
    await assert.rejects(db.exec("update public.site_promotions set starts_at = '2026-10-02', ends_at = '2026-10-01'"), /site_promotions_schedule/);
    await db.exec("insert into storage.objects (bucket_id, name) values ('site-promotions', 'allowed.png')");
    await assert.rejects(db.exec("insert into storage.objects (bucket_id, name) values ('unrelated', 'forbidden.png')"), /row-level security/);
    await db.exec("select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false)");
    assert.equal((await db.query("update storage.objects set name = 'hacked' returning id")).rows.length, 0);
  } finally { await db.close(); }
});
