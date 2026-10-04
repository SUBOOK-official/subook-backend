import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeIdentityDb, uid, migration } from './helpers/member-identity-db.js';
const hash = value => createHash('sha256').update(value).digest('hex');

test('번호 인증 후 계정 찾기 안내의 권한·마스킹·실제 로그인 수단', async t => {
  const db = await makeIdentityDb();
  const rpc = async (sql, args = []) => (await db.query(`select ${sql} result`, args)).rows[0].result;
  const as = n => db.query("select set_config('test.uid',$1,false)", [n ? uid(n) : '']);
  const account = async (n, email, providers = [], legacyPhone = null) => {
    await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,created_at)
      values($1,$2,now(),'{"provider":"email"}',now()-case when $3::text is null then interval '0' else interval '1 day' end)`, [uid(n), email, legacyPhone]);
    for (const provider of providers) await db.query('insert into auth.identities(user_id,provider) values($1,$2)', [uid(n), provider]);
    if (legacyPhone) {
      await db.query('insert into member_profiles(user_id,email,phone) values($1,$2,$3)', [uid(n), email, legacyPhone]);
      await db.query('insert into member_legacy_phone_accounts(user_id,phone) values($1,$2)', [uid(n), legacyPhone]);
    }
  };
  try {
    await db.exec('create role supabase_auth_admin');
    for (const name of ['20261001080300_restore_email_signup_phone_verification', '20261001091226_reject_duplicate_phone_signup',
      '20261001104338_align_phone_merge_eligibility', '20261001110924_verified_phone_account_hints',
      '20261004161015_remember_verified_account_login']) await db.exec(migration(name));
    await account(800, 'subook.owner@example.invalid', ['kakao']);
    await rpc('claim_kakao_member_phone($1,$2)', [uid(800), '01055550001']);
    await account(801, 'requester@example.invalid', ['google']); await as(801);
    await t.test('인증 전·잘못된 코드는 힌트 차단, 이미 확인한 계정 안내만 만료 뒤에도 유지', async () => {
      assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts, []);
      await db.query("update auth.users set raw_user_meta_data='{\"phone\":\"01055550001\",\"phone_verified\":true}' where id=$1", [uid(801)]);
      assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts, []);
      await db.query(`insert into phone_verification_codes(user_id,phone,code_hash,expires_at) values($1,'01055550001',$2,now()+interval '5 minutes')`, [uid(801), hash('123456' + uid(801))]);
      assert.equal((await rpc("verify_phone_otp('000000')")).success, false);
      assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts, []);
      await rpc("verify_phone_otp('123456')");
      const result = await rpc('get_my_member_identity()');
      assert.deepEqual(result.existing_accounts, [{ email_hint: 'su***@example.invalid', providers: ['kakao'] }]);
      assert.ok(!JSON.stringify(result).includes('subook.owner'));
      assert.ok(!JSON.stringify(result).includes(uid(800)));
      await db.query("update member_phone_proofs set expires_at=now()-interval '1 second' where user_id=$1", [uid(801)]);
      const remembered = await rpc('get_my_member_identity()');
      assert.deepEqual(remembered.existing_accounts, result.existing_accounts);
      assert.equal(remembered.existing_account_remembered, true);
      assert.equal(remembered.can_merge, false);
    });
    await t.test('실제 연결된 복수 로그인 수단을 안내하고 단순 provider metadata는 추측하지 않음', async () => {
      await rpc('claim_kakao_member_phone($1,$2)', [uid(801), '01055550001']);
      await db.query("insert into auth.identities(user_id,provider) values($1,'google'),($1,'email'),($1,'phone')", [uid(800)]);
      assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts[0].providers, ['email', 'google', 'kakao']);
    });
    await t.test('확정된 번호 소유자가 있으면 과거에 같은 번호를 적은 다른 계정은 노출하지 않음', async () => {
      await account(802, 'unverified.owner@example.invalid', ['google'], '01055550001');
      assert.equal((await rpc('get_my_member_identity()')).existing_accounts.length, 1);
    });
    await t.test('확정 소유자 없는 과거 계정은 여러 후보를 구분하고 짧은 이메일도 가림', async () => {
      await account(811, 'a@example.invalid', ['email'], '01055550002');
      await account(812, 'xy@example.invalid', ['google'], '01055550002');
      await rpc('claim_kakao_member_phone($1,$2)', [uid(801), '01055550002']);
      assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts.map(row => row.email_hint), ['*@example.invalid', 'x***@example.invalid']);
      await db.query('update member_profiles set personal_data_erased_at=now() where user_id=$1', [uid(811)]);
      assert.equal((await rpc('get_my_member_identity()')).existing_accounts.length, 1);
    });
    await t.test('이메일 가입도 올바른 OTP와 요청 비밀값을 모두 검증한 뒤에만 안내', async () => {
      const id = uid(820), secret = hash('request-secret'), code = hash('123456');
      await rpc('reserve_signup_phone_challenge($1,$2,$3,$4,$5,$6)', [id, 'signup@example.invalid', '01055550001', secret, code, hash('ip')]);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)', [id, hash('wrong'), code])).existing_accounts, undefined);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)', [id, secret, hash('wrong')])).existing_accounts, undefined);
      const result = await rpc('verify_signup_phone_challenge($1,$2,$3)', [id, secret, code]);
      assert.equal(result.status, 'existing_account');
      assert.equal(result.existing_accounts[0].email_hint, 'su***@example.invalid');
      await db.query("update member_signup_phone_challenges set expires_at=now()-interval '1 second' where id=$1", [id]);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)', [id, secret, code])).existing_accounts, undefined);
    });
    await t.test('휴대폰 단독 내부 이메일은 숨기고 비공개 조회를 차단', async () => {
      await account(830, 'internal@oauth.subook.local', ['phone'], '01055550003');
      await rpc('claim_kakao_member_phone($1,$2)', [uid(801), '01055550003']);
      assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts, [{ email_hint: null, providers: [] }]);
      for (const role of ['anon', 'authenticated']) assert.equal(await rpc("has_function_privilege($1,'public._member_existing_phone_accounts(text,uuid)','execute')", [role]), false);
      await as(null); await assert.rejects(rpc('get_my_member_identity()'), /로그인/);
      await as(800); assert.deepEqual((await rpc('get_my_member_identity()')).existing_accounts, []);
    });
  } finally { await db.close(); }
});
