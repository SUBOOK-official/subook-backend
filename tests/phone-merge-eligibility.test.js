import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeIdentityDb, uid, migration } from './helpers/member-identity-db.js';

test('번호 인증과 대표 계정 선택의 보호 조건 일치', async t => {
  const db = await makeIdentityDb();
  const rpc = async (sql, args = []) => (await db.query(`select ${sql} result`, args)).rows[0].result;
  const as = n => db.query("select set_config('test.uid',$1,false)", [uid(n)]);
  const phone = n => `0104444${String(n).padStart(4, '0')}`;
  const account = async (n, number, { admin = false, legacy = true, profile = true } = {}) => {
    await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,created_at)
      values($1,$2,now(),'{"provider":"google"}',now()-case when $3 then interval '1 day' else interval '0' end)`,
    [uid(n), `merge${n}@example.invalid`, legacy]);
    if (profile) await db.query(`insert into member_profiles(user_id,email,phone,terms_agreed_at,privacy_agreed_at)
      values($1,$2,$3,now(),now())`, [uid(n), `merge${n}@example.invalid`, number]);
    if (legacy && profile) await db.query('insert into member_legacy_phone_accounts(user_id,phone) values($1,$2)', [uid(n), number]);
    if (admin) await db.query('insert into admin_users(email) values($1)', [`merge${n}@example.invalid`]);
  };
  const verify = async (n, number) => {
    await as(n);
    await db.query(`insert into phone_verification_codes(user_id,phone,code_hash,expires_at) values($1,$2,$3,now()+interval '5 minutes')`,
      [uid(n), number, createHash('sha256').update('123456' + uid(n)).digest('hex')]);
    return rpc("verify_phone_otp('123456')");
  };
  try {
    await db.exec('create role supabase_auth_admin');
    await db.exec(migration('20261001080300_restore_email_signup_phone_verification'));
    await db.exec(migration('20261001091226_reject_duplicate_phone_signup'));
    await account(701, phone(701), { admin: true });
    await account(702, phone(701));
    await rpc('claim_kakao_member_phone($1,$2)', [uid(702), phone(701)]);
    await db.query('insert into member_phone_identities(phone,user_id) values($1,$2)', [phone(701), uid(702)]);
    // 운영 오류 재현: OTP는 통합을 요구하지만 다음 RPC는 관리자 보호 조건으로 거부했다.
    assert.equal((await verify(701, phone(701))).status, 'merge_required');
    await assert.rejects(rpc('start_member_account_merge()'), /통합할 수 없는 계정/);

    await db.exec(migration('20261001104338_align_phone_merge_eligibility'));
    await t.test('이미 오류 화면에 진입한 관리자 겸용 회원도 기존 로그인 안내로 복구', async () => {
      const identity = await rpc('get_my_member_identity()');
      assert.equal(identity.status, 'existing_account'); assert.equal(identity.can_merge, false);
      assert.equal((await verify(701, phone(701))).status, 'existing_account');
      await assert.rejects(rpc('start_member_account_merge()'), /기존 계정으로 로그인/);
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)', [uid(701), phone(701)])).status, 'existing_account');
      assert.equal((await db.query('select user_id from member_phone_identities where phone=$1', [phone(701)])).rows[0].user_id, uid(702));
      assert.equal(Number((await db.query('select count(*) from member_merge_requests')).rows[0].count), 0);
      assert.equal(Number((await db.query('select count(*) from admin_users')).rows[0].count), 1);
    });
    await t.test('신규 계정/회원 프로필 없는 과거 OAuth도 불가능한 통합으로 진입하지 않음', async () => {
      for (const [n, options] of [[703, { legacy: false, profile: false }], [704, { profile: false }]]) {
        await account(n, phone(701), options);
        assert.equal((await verify(n, phone(701))).status, 'existing_account');
        assert.equal((await rpc('get_my_member_identity()')).can_merge, false);
        assert.equal(Number((await db.query('select count(*) from member_profiles where user_id=$1', [uid(n)])).rows[0].count), 0);
      }
    });
    await t.test('현재 번호 소유자가 보호된 계정이면 다른 일반 회원도 통합 불가 안내', async () => {
      await account(705, phone(705), { admin: true });
      await account(706, phone(705)); await account(707, phone(705));
      await db.query('insert into member_phone_identities(phone,user_id) values($1,$2)', [phone(705), uid(705)]);
      assert.equal((await verify(706, phone(705))).status, 'existing_account');
      assert.equal((await rpc('get_my_member_identity()')).can_merge, false);
    });
    await t.test('전환 뒤 생성된 번호 소유자는 기존 회원과 통합할 수 없음', async () => {
      await account(708, phone(708), { legacy: false });
      await account(709, phone(708));
      await db.query('insert into member_phone_identities(phone,user_id) values($1,$2)', [phone(708), uid(708)]);
      assert.equal((await verify(709, phone(708))).status, 'existing_account');
    });
    await t.test('일반 기존 중복 회원은 각 로그인 확인 후 대표 선택 통합 유지', async () => {
      await account(710, phone(710)); await account(711, phone(710));
      assert.equal((await verify(710, phone(710))).status, 'merge_required');
      assert.equal((await rpc('get_my_member_identity()')).can_merge, true);
      const request = await rpc('start_member_account_merge()');
      assert.equal(request.accounts.length, 2);
      await as(711);
      await db.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ amr: [{ method: 'oauth', timestamp: Math.floor(Date.now() / 1000) + 1 }] })]);
      await rpc('prove_member_account_merge($1,$2)', [request.id, request.secret]);
      assert.equal((await rpc('complete_member_account_merge($1,$2,$3)', [request.id, request.secret, uid(711)])).success, true);
    });
    await t.test('번호 충돌 없는 관리자 겸용 회원의 일반 번호 인증은 유지', async () => {
      await account(712, phone(712), { admin: true });
      assert.equal((await verify(712, phone(712))).status, 'verified');
      const identity = await rpc('get_my_member_identity()');
      assert.equal(identity.status, 'verified'); assert.equal(identity.can_merge, false);
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)', [uid(712), phone(712)])).status, 'verified');
    });
    await t.test('만료된 번호 증명은 다시 인증하고, 내부 후보 조회는 공개하지 않음', async () => {
      await as(701); await db.query("update member_phone_proofs set expires_at=now()-interval '1 second' where user_id=$1", [uid(701)]);
      assert.equal((await rpc('get_my_member_identity()')).can_merge, false);
      assert.equal((await rpc('get_my_member_identity()')).status, 'unverified');
      for (const role of ['anon', 'authenticated']) {
        assert.equal(await rpc("has_function_privilege($1,'public._member_phone_merge_candidates(uuid,text)','EXECUTE')", [role]), false);
      }
    });
  } finally { await db.close(); }
});
