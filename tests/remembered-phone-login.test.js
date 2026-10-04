import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeIdentityDb, uid, migration } from './helpers/member-identity-db.js';

test('이미 확인한 기존 계정은 재로그인 시 SMS 없이 안내하고 인증 권한은 재사용하지 않는다', async t => {
  const db = await makeIdentityDb();
  const rpc = async (sql, args = []) => (await db.query(`select ${sql} result`, args)).rows[0].result;
  const as = n => db.query("select set_config('test.uid',$1,false)", [n ? uid(n) : '']);
  const phone = n => `0104400${String(n).padStart(4, '0')}`;
  const account = async (n, { legacyPhone, admin = false, provider = 'google' } = {}) => {
    await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,created_at)
      values($1,$2,now(),'{"provider":"google"}',now()-case when $3::text is null then interval '0' else interval '1 day' end)`,
    [uid(n), `member${n}@example.invalid`, legacyPhone || null]);
    await db.query('insert into auth.identities(user_id,provider) values($1,$2)', [uid(n), provider]);
    if (legacyPhone) {
      await db.query('insert into member_profiles(user_id,email,phone) values($1,$2,$3)', [uid(n), `member${n}@example.invalid`, legacyPhone]);
      await db.query('insert into member_legacy_phone_accounts(user_id,phone) values($1,$2)', [uid(n), legacyPhone]);
    }
    if (admin) await db.query('insert into admin_users(email) values($1)', [`member${n}@example.invalid`]);
  };
  const otp = async (n, number, code = '123456') => {
    await as(n);
    await db.query(`insert into phone_verification_codes(user_id,phone,code_hash,expires_at)
      values($1,$2,$3,now()+interval '5 minutes')`, [uid(n), number, createHash('sha256').update('123456' + uid(n)).digest('hex')]);
    return rpc('verify_phone_otp($1)', [code]);
  };
  const expire = n => db.query("update member_phone_proofs set expires_at=now()-interval '1 second' where user_id=$1", [uid(n)]);
  const identity = () => rpc('get_my_member_identity()');
  const hints = [{ email_hint: 'me***@example.invalid', providers: ['kakao'] }];
  try {
    await db.exec('create role supabase_auth_admin');
    for (const name of ['20261001080300_restore_email_signup_phone_verification', '20261001091226_reject_duplicate_phone_signup',
      '20261001104338_align_phone_merge_eligibility', '20261001110924_verified_phone_account_hints']) await db.exec(migration(name));
    await account(901, { provider: 'kakao' });
    await rpc('claim_kakao_member_phone($1,$2)', [uid(901), phone(901)]);
    await account(902);
    assert.equal((await otp(902, phone(901))).status, 'existing_account');
    await expire(902);
    // 이번 장애: 검증 기록은 남아 있는데 만료되면 첫 SMS 화면으로 되돌아갔다.
    assert.equal((await identity()).status, 'unverified');
    await db.exec(migration('20261004161015_remember_verified_account_login'));

    await t.test('배포 전 만료 기록도 재인증 없이 복원하고 번호 소유권은 주지 않는다', async () => {
      const result = await identity();
      assert.equal(result.status, 'existing_account');
      assert.equal(result.existing_account_remembered, true);
      assert.deepEqual(result.existing_accounts, hints);
      assert.equal(result.phone, null);
      assert.equal(result.can_merge, false);
      assert.equal(await rpc('member_identity_is_ready()'), false);
      assert.equal((await db.query('select expires_at<now() expired from member_phone_proofs where user_id=$1', [uid(902)])).rows[0].expired, true);
      assert.equal(Number((await db.query('select count(*) from member_phone_identities where user_id=$1', [uid(902)])).rows[0].count), 0);
    });
    await t.test('로그아웃·다른 사용자·재로그인에도 본인의 안내만 조회한다', async () => {
      await as(null); await assert.rejects(identity(), /로그인/);
      await account(903); await as(903);
      assert.equal((await identity()).status, 'unverified');
      assert.deepEqual((await identity()).existing_accounts, []);
      await as(902); assert.deepEqual((await identity()).existing_accounts, hints);
    });
    await t.test('이후 OTP 성공 시 안내 대상 ID를 보관하며 20분 경과 후에도 유지한다', async () => {
      assert.equal((await otp(903, phone(901))).status, 'existing_account');
      assert.equal((await identity()).existing_account_remembered, false);
      assert.deepEqual((await db.query('select login_hint_account_ids from member_phone_proofs where user_id=$1', [uid(903)])).rows[0].login_hint_account_ids, [uid(901)]);
      await expire(903);
      assert.equal((await identity()).existing_account_remembered, true);
      assert.deepEqual((await identity()).existing_accounts, hints);
      assert.ok(!JSON.stringify(await identity()).includes(uid(901)));
      assert.ok(!JSON.stringify(await identity()).includes(phone(901)));
      await assert.rejects(rpc('start_member_account_merge()'), /기존 계정/);
    });
    await t.test('잘못된 코드·메타데이터 입력만으로 다른 계정 안내를 만들 수 없다', async () => {
      await account(904);
      await db.query("update auth.users set raw_user_meta_data=$2 where id=$1", [uid(904), { phone: phone(901), phone_verified: true, existing_account_remembered: true }]);
      assert.equal((await otp(904, phone(901), '000000')).success, false);
      assert.deepEqual((await identity()).existing_accounts, []);
      assert.equal(Number((await db.query('select count(*) from member_phone_proofs where user_id=$1', [uid(904)])).rows[0].count), 0);
    });
    await t.test('다른 번호의 인증 실패는 기존 안내를 지우지 않고 성공해야 교체한다', async () => {
      assert.equal((await otp(903, phone(905), '000000')).success, false);
      assert.deepEqual((await identity()).existing_accounts, hints);
      assert.equal((await rpc("verify_phone_otp('123456')")).status, 'verified');
      assert.equal((await identity()).status, 'verified');
      assert.equal((await identity()).existing_account_remembered, false);
      assert.deepEqual((await identity()).existing_accounts, []);
      assert.deepEqual((await db.query('select login_hint_account_ids from member_phone_proofs where user_id=$1', [uid(903)])).rows[0].login_hint_account_ids, []);
    });
    await t.test('저장 후 차단·탈퇴·파기·통합된 계정은 안내하지 않는다', async () => {
      await account(906); await otp(906, phone(901)); await expire(906);
      for (const column of ['is_blocked', 'withdrawal_requested_at', 'personal_data_erased_at']) {
        await db.exec(`update member_profiles set ${column}=${column === 'is_blocked' ? 'true' : 'now()'} where user_id='${uid(901)}'`);
        assert.deepEqual((await identity()).existing_accounts, [], column);
        await db.exec(`update member_profiles set ${column}=${column === 'is_blocked' ? 'false' : 'null'} where user_id='${uid(901)}'`);
      }
      await db.query('insert into member_account_merges(source_user_id,target_user_id) values($1,$2)', [uid(901), uid(903)]);
      assert.deepEqual((await identity()).existing_accounts, []);
      await db.query('delete from member_account_merges where source_user_id=$1', [uid(901)]);
    });
    await t.test('번호 소유자가 변경되면 새 소유자를 이전 인증으로 노출하지 않는다', async () => {
      await account(907, { provider: 'kakao' });
      await rpc('claim_kakao_member_phone($1,$2)', [uid(907), phone(907)]);
      await account(908); await otp(908, phone(907)); await expire(908);
      await account(909, { provider: 'google' });
      await db.query('update member_phone_identities set user_id=$1 where phone=$2', [uid(909), phone(907)]);
      await db.query('insert into member_profiles(user_id,email) values($1,$2)', [uid(909), 'member909@example.invalid']);
      assert.equal((await identity()).status, 'unverified');
      assert.deepEqual((await identity()).existing_accounts, []);
    });
    await t.test('정상 기존 계정 통합에는 여전히 유효한 번호 증명이 필요하다', async () => {
      await account(920, { legacyPhone: phone(920) }); await account(921, { legacyPhone: phone(920) });
      assert.equal((await otp(920, phone(920))).status, 'merge_required');
      assert.equal((await identity()).can_merge, true);
      await expire(920);
      assert.equal((await identity()).can_merge, false);
      assert.equal((await identity()).status, 'unverified');
      await assert.rejects(rpc('start_member_account_merge()'), /다시 인증/);
    });
    await t.test('관리자 겸용 기존 계정도 재인증 반복 없이 기존 계정으로 안내한다', async () => {
      await account(930, { legacyPhone: phone(930), admin: true });
      await account(931, { legacyPhone: phone(930), provider: 'kakao' });
      await db.query('insert into member_phone_identities(phone,user_id) values($1,$2)', [phone(930), uid(931)]);
      assert.equal((await otp(930, phone(930))).status, 'existing_account');
      await expire(930);
      assert.deepEqual((await identity()).existing_accounts, hints);
      assert.equal((await identity()).can_merge, false);
      await assert.rejects(rpc('start_member_account_merge()'), /다시 인증/);
    });
    await t.test('예전 기록 복원은 인증 시점 이후에 등장한 번호 소유자에게 적용하지 않는다', async () => {
      await account(940, { provider: 'kakao' }); await rpc('claim_kakao_member_phone($1,$2)', [uid(940), phone(940)]);
      await account(941); await otp(941, phone(940)); await expire(941);
      await db.query('update member_phone_proofs set login_hint_account_ids=null where user_id=$1', [uid(941)]);
      await db.query("update member_phone_identities set verified_at=now()+interval '1 second' where user_id=$1", [uid(940)]);
      assert.equal((await identity()).status, 'unverified');
    });
    await t.test('기록·비공개 함수는 일반 사용자가 직접 조회하거나 위조할 수 없다', async () => {
      for (const role of ['anon', 'authenticated']) {
        for (const func of ['_member_existing_phone_account_ids(text,uuid)', '_member_phone_login_hints(text,uuid,uuid[])', 'remember_member_phone_login_hint()', '_member_existing_phone_accounts(text,uuid)']) {
          assert.equal(await rpc("has_function_privilege($1,$2,'execute')", [role, `public.${func}`]), false);
        }
        for (const privilege of ['select', 'insert', 'update']) {
          assert.equal(await rpc('has_table_privilege($1,$2,$3)', [role, 'public.member_phone_proofs', privilege]), false);
        }
      }
      assert.equal((await db.query("select relrowsecurity from pg_class where oid='public.member_phone_proofs'::regclass")).rows[0].relrowsecurity, true);
    });
  } finally { await db.close(); }
});
