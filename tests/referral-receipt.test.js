import test from 'node:test';
import assert from 'node:assert/strict';
import { makeIdentityDb, migration, uid } from './helpers/member-identity-db.js';

test('초대 지급 내역: 실제 지급 후 본인에게만 표시하고 친구 이름을 마스킹한다', async (t) => {
  const db = await makeIdentityDb();
  const as = (n) => db.query("select set_config('test.uid', $1, false)", [n ? uid(n) : '']);
  const rpc = async (sql, args = []) => (await db.query(`select ${sql} as result`, args)).rows[0].result;
  const summary = () => rpc('public.get_my_signup_referral()');
  const add = async (n, complete = true) => {
    await as(null);
    await db.query(`insert into auth.users(id, email, email_confirmed_at, raw_app_meta_data)
      values($1, $2, now(), '{"provider":"kakao"}')`, [uid(n), `receipt${n}@example.invalid`]);
    await rpc('public.claim_kakao_member_phone($1, $2)', [uid(n), `01000000${String(n).padStart(3, '0')}`]);
    await as(n);
    if (complete) await rpc("public.complete_oauth_signup(false, '김수북', null)");
  };
  try {
    await db.exec('create role supabase_auth_admin');
    await db.exec(migration('20261001080300_restore_email_signup_phone_verification'));
    await db.exec(migration('20261001091226_reject_duplicate_phone_signup'));
    await db.exec(migration('20261001095523_referral_reward_receipt'));
    await add(1);
    const invitation = await summary();
    assert.equal(invitation.sent_reward, null);
    await add(2, false);
    await rpc('public.attach_signup_referral($1)', [invitation.code]);

    await t.test('가입 미완료는 완료 내역이 없고 두 쿠폰이 지급된 시점부터 표시한다', async () => {
      await as(1); assert.equal((await summary()).sent_reward, null);
      await as(2); await rpc("public.complete_oauth_signup(false, '김수북', null)");
      assert.equal((await rpc('public.complete_signup_referral()')).status, 'rewarded');
      await as(1);
      const result = await summary();
      assert.equal(result.can_invite, false);
      assert.equal(result.reward_count, 1);
      assert.equal(result.sent_reward.friend_name, '김*북');
      const rows = (await db.query('select issued_at from member_coupons order by id')).rows;
      assert.equal(rows.length, 2);
      assert.equal(rows[0].issued_at.getTime(), rows[1].issued_at.getTime());
      assert.equal(new Date(result.sent_reward.rewarded_at).getTime(), rows[0].issued_at.getTime());
      assert.deepEqual(Object.keys(result.sent_reward).sort(), ['friend_name', 'rewarded_at']);
      assert.equal((await rpc('public.get_signup_referral_offer($1)', [invitation.code])).code_expired, true);
      await as(2);
      assert.equal((await summary()).received_reward, true);
      assert.equal((await summary()).sent_reward, null);
    });
    await t.test('타 회원·비로그인·공개 조회에는 친구 이름과 지급 내역이 노출되지 않는다', async () => {
      await add(3);
      await db.exec('set role authenticated');
      assert.equal((await summary()).sent_reward, null);
      await assert.rejects(db.query('select * from member_referral_signups'), /permission denied/);
      await db.exec('reset role; set role anon');
      await assert.rejects(summary(), /permission denied/);
      assert.equal((await rpc('public.get_signup_referral_offer($1)', [invitation.code])).sent_reward, undefined);
      await db.exec('reset role'); await as(null);
      await assert.rejects(summary(), /로그인/);
    });
    await t.test('이름 없음·짧은 이름·탈퇴 및 개인정보 삭제에도 발급 기록은 유지한다', async () => {
      await as(1);
      for (const [name, expected] of [[null, null], ['  ', null], ['김', '*'], ['수북', '수*'], ['김수북', '김*북']]) {
        await db.query('update member_profiles set name=$1 where user_id=$2', [name, uid(2)]);
        assert.equal((await summary()).sent_reward.friend_name, expected);
      }
      await db.query('update member_profiles set withdrawal_requested_at=now() where user_id=$1', [uid(2)]);
      assert.equal((await summary()).sent_reward.friend_name, null);
      await db.query('update member_profiles set personal_data_erased_at=now() where user_id=$1', [uid(2)]);
      assert.ok((await summary()).sent_reward.rewarded_at);
      assert.equal((await summary()).sent_reward.friend_name, null);
    });
    await t.test('대표 계정이 승계한 기존 초대도 완료 내역을 표시하며 다시 발급하지 않는다', async () => {
      await db.query('insert into member_account_merges(source_user_id,target_user_id) values($1,$2)', [uid(1), uid(3)]);
      await as(3);
      const result = await summary();
      assert.equal(result.can_invite, false);
      assert.ok(result.sent_reward.rewarded_at);
      await summary();
      assert.equal((await db.query('select count(*) from member_coupons')).rows[0].count, 2);
    });
  } finally { await db.close(); }
});
