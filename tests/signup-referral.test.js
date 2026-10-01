import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const uid = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const migration = (name) => readFileSync(new URL(`../supabase/migrations/${name}.sql`, import.meta.url), 'utf8');

test('친구 초대: 가입 완료 시 동시 지급, 재시도, 권한 및 발급 실패 원자성', async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated; create schema auth;
      create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
      grant usage on schema auth to anon, authenticated;
      create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz,
        encrypted_password text, raw_app_meta_data jsonb, raw_user_meta_data jsonb default '{}', created_at timestamptz default now());
      create table public.member_profiles (user_id uuid primary key references auth.users(id), email text, name text, nickname text,
        phone text, marketing_opt_in boolean default false, marketing_agreed_at timestamptz,
        terms_agreed_at timestamptz, privacy_agreed_at timestamptz, email_verified_at timestamptz,
        withdrawal_requested_at timestamptz, personal_data_erased_at timestamptz, is_blocked boolean default false, updated_at timestamptz);
      create function public.assert_member_not_blocked() returns void language plpgsql as $$ begin
        if exists (select 1 from public.member_profiles where user_id=auth.uid() and is_blocked) then raise exception 'blocked'; end if; end $$;
      create table public.coupons (id bigint generated always as identity primary key, title text, description text, discount_type text,
        discount_value integer, min_order_amount integer, valid_days integer, valid_until timestamptz, valid_from timestamptz,
        usage_limit_per_user integer, issuance_type text, campaign_key text unique, is_active boolean default true,
        issued_count integer default 0, total_quantity integer);
      create table public.member_coupons (id bigint generated always as identity primary key, coupon_id bigint references public.coupons(id),
        user_id uuid references auth.users(id), issued_at timestamptz default now(), expires_at timestamptz);
      create function public.compute_coupon_member_expiry(integer, timestamptz) returns timestamptz language sql as $$
        select case when $1 is not null then now()+make_interval(days=>$1) else $2 end $$;
    `);
    await db.exec(migration('20260724053221_harden_member_profile_sync'));
    await db.exec(migration('20260525135915_complete_signup_with_name_phone'));
    await db.exec('create trigger sync_profile after insert or update on auth.users for each row execute function public.sync_member_profile_from_auth()');
    const add = async (n, provider = 'email', complete = false) => db.query(`insert into auth.users
      (id,email,email_confirmed_at,encrypted_password,raw_app_meta_data,raw_user_meta_data) values($1,$2,now(),$3,$4,$5)`,
    [uid(n), `test${n}@example.invalid`, complete ? 'hashed-password' : '', { provider }, complete ? { terms_agreed_at: new Date().toISOString(), privacy_agreed_at: new Date().toISOString() } : {}]);
    const as = (n) => db.query("select set_config('test.uid', $1, false)", [uid(n)]);
    const finish = () => db.query('select public.complete_signup_referral() as result');
    const count = async () => Number((await db.query('select count(*) from public.member_coupons')).rows[0].count);
    const attach = (code) => db.query('select public.attach_signup_referral($1)', [code]);
    const emailComplete = (n) => db.query(`update auth.users set encrypted_password='hashed-password',
      raw_user_meta_data='{"terms_agreed_at":"2026-10-01T00:00:00Z","privacy_agreed_at":"2026-10-01T00:00:00Z"}' where id=$1`, [uid(n)]);
    await add(1, 'email', true); // 출시 전 회원도 초대할 수 있지만 신규 혜택은 받을 수 없음
    await db.exec(migration('20261001042015_signup_referral_coupons'));
    await db.exec(migration('20261001053820_single_use_signup_referrals'));
    await as(1);
    const code = (await db.query('select public.get_my_signup_referral() as result')).rows[0].result.code;
    assert.match(code, /^[a-f0-9]{32}$/);

    await t.test('기존 회원/자기 초대/직접 쓰기/타인 발급 API 접근 차단', async () => {
      await assert.rejects(attach(code), /신규 가입/);
      await db.exec('set role anon');
      const offer = (await db.query('select public.get_signup_referral_offer($1) as offer', [code])).rows[0].offer;
      assert.equal(offer.code_valid, true);
      assert.equal(offer.amount, 4000);
      assert.equal(offer.min_order_amount, 30000);
      await assert.rejects(db.query('select * from public.member_referral_signups'), /permission denied/);
      await assert.rejects(finish(), /permission denied/);
      await db.exec('reset role; set role authenticated');
      await assert.rejects(db.query('select public._complete_signup_referral($1)', [uid(1)]), /permission denied/);
      await assert.rejects(db.query('insert into public.member_referral_codes(user_id) values($1)', [uid(1)]), /permission denied/);
      await db.exec('reset role');
    });
    await t.test('이메일 OTP 인증만으로는 지급하지 않고 가입 정보 저장 시 같은 시각에 2장 지급', async () => {
      await add(2); await as(2); await attach(code);
      assert.equal((await finish()).rows[0].result.status, 'pending');
      assert.equal(await count(), 0);
      await emailComplete(2);
      assert.equal(await count(), 2);
      const rows = (await db.query('select * from public.member_coupons order by id')).rows;
      assert.deepEqual(rows.map((r) => r.user_id), [uid(1), uid(2)]);
      assert.equal(rows[0].issued_at.getTime(), rows[1].issued_at.getTime());
      assert.equal(rows[0].expires_at.getTime(), rows[1].expires_at.getTime());
      assert.equal((rows[0].expires_at - rows[0].issued_at) / 86400000, 30);
      await Promise.all(Array.from({ length: 8 }, () => finish()));
      await attach(code);
      assert.equal(await count(), 2);
    });
    await t.test('한 번 지급한 초대 링크는 만료되고 초대받은 회원의 새 초대는 별도로 1회 가능', async () => {
      assert.equal((await db.query('select public.get_signup_referral_offer($1) as result', [code])).rows[0].result.code_valid, false);
      assert.equal((await db.query('select public.get_signup_referral_offer($1) as result', [code])).rows[0].result.code_expired, true);
      for (const [n, provider] of [[3, 'kakao'], [4, 'google']]) {
        await as(n - 1);
        const nextCode = (await db.query('select public.get_my_signup_referral() as result')).rows[0].result.code;
        await add(n, provider); await as(n);
        await assert.rejects(attach(code), /사용할 수 없는/);
        await attach(nextCode);
        assert.equal((await finish()).rows[0].result.status, 'pending');
        await db.query("select public.complete_oauth_signup(false, '테스트', '01000000000')");
        assert.equal((await finish()).rows[0].result.status, 'rewarded');
      }
      assert.equal(await count(), 6);
      await as(1);
      const summary = (await db.query('select public.get_my_signup_referral() as result')).rows[0].result;
      assert.equal(summary.reward_count, 1);
      assert.equal(summary.can_invite, false);
      assert.deepEqual(Object.keys(summary).sort(), ['can_invite', 'code', 'received_reward', 'reward_count']);
    });
    await t.test('가입 후 링크 소급 적용과 초대자 바꿔치기 차단', async () => {
      await add(5, 'email', true); await as(5);
      await assert.rejects(attach(code), /가입을 완료/);
      await as(4);
      const nextCode = (await db.query('select public.get_my_signup_referral() as result')).rows[0].result.code;
      await add(6); await as(6); await attach(nextCode);
      await assert.rejects(attach('f'.repeat(32)), /다른 초대 링크/);
    });
    await t.test('두 번째 쿠폰 INSERT 실패 시 첫 쿠폰도 롤백, 회원가입 보존 후 재시도 가능', async () => {
      await db.exec(`create function public.test_reject_friend() returns trigger language plpgsql as $$ begin
        if new.user_id='${uid(6)}' then raise exception 'simulated issue failure'; end if; return new; end $$;
        create trigger test_reject_friend before insert on public.member_coupons for each row execute function public.test_reject_friend()`);
      await emailComplete(6);
      assert.equal(await count(), 6);
      assert.equal((await db.query('select encrypted_password from auth.users where id=$1', [uid(6)])).rows[0].encrypted_password, 'hashed-password');
      await db.exec('drop trigger test_reject_friend on public.member_coupons');
      assert.equal((await finish()).rows[0].result.status, 'rewarded');
      assert.equal(await count(), 8);
    });
    await t.test('쿠폰 수량 소진/차단 회원은 한쪽만 지급되지 않음', async () => {
      await as(6);
      const nextCode = (await db.query('select public.get_my_signup_referral() as result')).rows[0].result.code;
      await add(7, 'google'); await as(7); await attach(nextCode);
      await db.exec("update coupons set total_quantity=issued_count where campaign_key='signup_referral_friend'");
      await db.query("select public.complete_oauth_signup(false, '테스트', '01000000000')");
      assert.equal((await finish()).rows[0].result.status, 'unavailable');
      assert.equal(await count(), 8);
      await db.exec('update coupons set total_quantity=null');
      await db.query('update member_profiles set is_blocked=true where user_id=$1', [uid(6)]);
      assert.equal((await finish()).rows[0].result.status, 'unavailable');
      assert.equal(await count(), 8);
    });
    await t.test('여러 친구가 미리 링크를 연결해도 첫 완료만 두 장을 받고 나머지는 만료 처리', async () => {
      await add(8, 'email', true); await as(8);
      const nextCode = (await db.query('select public.get_my_signup_referral() as result')).rows[0].result.code;
      for (const n of [9, 10]) { await add(n); await as(n); await attach(nextCode); }
      await emailComplete(9); await emailComplete(10);
      assert.equal(await count(), 10);
      await as(10);
      assert.equal((await finish()).rows[0].result.status, 'expired');
      assert.equal((await db.query('select completed_at from member_referral_signups where invitee_id=$1', [uid(10)])).rows[0].completed_at !== null, true);
      assert.equal((await db.query('select count(*) from member_coupons where user_id=$1', [uid(8)])).rows[0].count, 1);
    });
  } finally { await db.close(); }
});
