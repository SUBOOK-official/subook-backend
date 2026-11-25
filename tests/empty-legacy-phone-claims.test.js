import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeIdentityDb, uid, migration } from './helpers/member-identity-db.js';

// 2026-11-26 제보: 이력 있는 본 계정이 번호를 인증했는데 같은 번호가 적힌 빈 계정들로 로그인하라고 안내했다.
test('이력 없는 전환 전 계정의 번호 기록은 번호 인증을 막지 않는다', async t => {
  const db = await makeIdentityDb();
  const rpc = async (sql, args = []) => (await db.query(`select ${sql} result`, args)).rows[0].result;
  const as = n => db.query("select set_config('test.uid',$1,false)", [n ? uid(n) : '']);
  const phone = n => `0105500${String(n).padStart(4, '0')}`;
  const email = (n, tag) => `${tag}${n}@example.invalid`;
  // tag는 마스킹 뒤에도 계정을 구분하기 위한 이메일 앞 두 글자.
  const account = async (n, tag, { number = null, legacy = true, profile = true, admin = false, provider = 'email' } = {}) => {
    await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,created_at)
      values($1,$2,now(),'{"provider":"email"}',now()-case when $3 then interval '1 day' else interval '0' end)`,
    [uid(n), email(n, tag), legacy]);
    await db.query('insert into auth.identities(user_id,provider) values($1,$2)', [uid(n), provider]);
    if (profile) await db.query('insert into member_profiles(user_id,email,phone) values($1,$2,$3)', [uid(n), email(n, tag), number]);
    if (profile && legacy && number) await db.query('insert into member_legacy_phone_accounts(user_id,phone) values($1,$2)', [uid(n), number]);
    if (admin) await db.query('insert into admin_users(email) values($1)', [email(n, tag)]);
  };
  const order = n => db.query('insert into orders(user_id,total_amount) values($1,10000)', [uid(n)]);
  const otp = async (n, number) => {
    await as(n);
    await db.query(`insert into phone_verification_codes(user_id,phone,code_hash,expires_at)
      values($1,$2,$3,now()+interval '5 minutes')`, [uid(n), number, createHash('sha256').update('123456' + uid(n)).digest('hex')]);
    return rpc("verify_phone_otp('123456')");
  };
  const identity = () => rpc('get_my_member_identity()');
  const owner = async number => (await db.query('select user_id from member_phone_identities where phone=$1', [number])).rows[0]?.user_id;
  const hint = (tag, provider = 'email') => ({ email_hint: `${tag}***@example.invalid`, providers: [provider] });
  try {
    await db.exec('create role supabase_auth_admin');
    for (const name of ['20261001080300_restore_email_signup_phone_verification', '20261001091226_reject_duplicate_phone_signup',
      '20261001104338_align_phone_merge_eligibility', '20261001110924_verified_phone_account_hints',
      '20261004161015_remember_verified_account_login']) await db.exec(migration(name));

    // 제보 재현: 주문 있는 관리자 겸용 본 계정 + 같은 번호가 적힌 빈 계정 2개 + 다른 번호로 이미 인증한 계정.
    await account(1101, 'ma', { number: phone(1101), admin: true, provider: 'google' }); await order(1101);
    await account(1102, 'be', { number: phone(1101) });
    await account(1103, 'so', { number: phone(1101) });
    await account(1104, 'yo', { number: phone(1101), provider: 'kakao' });
    await db.query('insert into member_phone_identities(phone,user_id) values($1,$2)', [phone(1199), uid(1104)]);
    assert.equal((await otp(1101, phone(1101))).status, 'existing_account');
    assert.deepEqual((await identity()).existing_accounts, [hint('be'), hint('so')]);
    await db.query("update member_phone_proofs set expires_at=now()-interval '1 second' where user_id=$1", [uid(1101)]);
    assert.equal((await identity()).existing_account_remembered, true);

    await db.exec(migration('20261125152019_release_empty_legacy_phone_claims'));

    await t.test('제보 계정: 빈 계정 안내가 사라지고 다시 인증하면 본 계정이 번호 주인이 된다', async () => {
      await as(1101);
      const before = await identity();
      assert.equal(before.status, 'unverified');
      assert.deepEqual(before.existing_accounts, []);
      assert.equal(before.existing_account_remembered, false);
      assert.equal((await otp(1101, phone(1101))).status, 'verified');
      assert.equal(await owner(phone(1101)), uid(1101));
      assert.equal((await identity()).status, 'verified');
      assert.deepEqual((await db.query('select login_hint_account_ids from member_phone_proofs where user_id=$1', [uid(1101)])).rows[0].login_hint_account_ids, []);
      // 빈 계정과 그 번호 기록은 지우지 않는다. 관리자 권한도 그대로다.
      assert.equal(Number((await db.query('select count(*) from member_legacy_phone_accounts where phone=$1', [phone(1101)])).rows[0].count), 4);
      assert.equal(Number((await db.query('select count(*) from member_profiles where user_id=any($1)', [[uid(1102), uid(1103)]])).rows[0].count), 2);
      assert.equal(Number((await db.query('select count(*) from admin_users')).rows[0].count), 1);
    });
    await t.test('빈 계정으로 들어오면 번호 주인인 본 계정 하나만 안내하고 통합으로 번호를 가져갈 수 없다', async () => {
      assert.equal((await otp(1102, phone(1101))).status, 'existing_account');
      const result = await identity();
      assert.deepEqual(result.existing_accounts, [hint('ma', 'google')]);
      assert.equal(result.can_merge, false);
      await assert.rejects(rpc('start_member_account_merge()'), /기존 계정으로 로그인/);
      assert.equal(await owner(phone(1101)), uid(1101));
    });
    await t.test('본 계정이 인증하기 전에도 빈 계정끼리 통합해 번호를 선점할 수 없다', async () => {
      await account(1111, 'ma', { number: phone(1111), admin: true }); await order(1111);
      await account(1112, 'be', { number: phone(1111) }); await account(1113, 'so', { number: phone(1111) });
      assert.equal((await otp(1112, phone(1111))).status, 'existing_account');
      assert.deepEqual((await identity()).existing_accounts, [hint('ma')]);
      await assert.rejects(rpc('start_member_account_merge()'), /기존 계정으로 로그인/);
      assert.equal(await owner(phone(1111)), undefined);
      assert.equal((await otp(1111, phone(1111))).status, 'verified');
    });
    await t.test('전부 빈 계정인 묶음은 먼저 인증한 계정이 바로 인증된다', async () => {
      await account(1121, 'aa', { number: phone(1121) }); await account(1122, 'bb', { number: phone(1121), provider: 'kakao' });
      assert.equal((await otp(1122, phone(1121))).status, 'verified');
      assert.equal(await owner(phone(1121)), uid(1122));
      // 나머지 계정은 인증된 번호 주인과의 기존 통합 안내를 그대로 받는다.
      assert.equal((await otp(1121, phone(1121))).status, 'merge_required');
      assert.equal(await owner(phone(1121)), uid(1122));
    });
    await t.test('번호를 적지 않았던 전환 전 회원도 빈 계정의 번호 기록에 막히지 않는다', async () => {
      await account(1131, 'np'); await account(1132, 'ee', { number: phone(1131) });
      assert.equal((await otp(1131, phone(1131))).status, 'verified');
    });
    await t.test('카카오가 인증한 번호도 같은 규칙을 따른다', async () => {
      await account(1136, 'kk', { number: phone(1136), provider: 'kakao' }); await account(1137, 'ee', { number: phone(1136) });
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)', [uid(1136), phone(1136)])).status, 'verified');
    });
    await t.test('한 계정만 이력이 있으면 그 계정은 바로 인증되고, 빈 계정 쪽에서는 통합을 안내한다', async () => {
      await account(1141, 'us', { number: phone(1141) }); await order(1141); await account(1142, 'ee', { number: phone(1141) });
      assert.equal((await otp(1141, phone(1141))).status, 'verified');
      await account(1143, 'us', { number: phone(1143) }); await account(1144, 'ee', { number: phone(1143) });
      await db.query('insert into pickup_requests(user_id) values($1)', [uid(1143)]);
      assert.equal((await otp(1144, phone(1143))).status, 'merge_required');
      assert.equal((await identity()).can_merge, true);
      assert.equal((await rpc('start_member_account_merge()')).accounts.length, 2);
    });
    await t.test('이력 있는 계정이 둘 이상이면 그 계정들만 대표 계정 선택 통합으로 간다', async () => {
      await account(1151, 'ua', { number: phone(1151) }); await order(1151);
      await account(1152, 'ub', { number: phone(1151) }); await order(1152);
      await account(1153, 'ee', { number: phone(1151) });
      assert.equal((await otp(1151, phone(1151))).status, 'merge_required');
      const request = await rpc('start_member_account_merge()');
      assert.deepEqual(request.accounts.map(a => a.id).sort(), [uid(1151), uid(1152)]);
      await as(1152);
      await db.query("select set_config('request.jwt.claims',$1,false)", [JSON.stringify({ amr: [{ method: 'oauth', timestamp: Math.floor(Date.now() / 1000) + 1 }] })]);
      await rpc('prove_member_account_merge($1,$2)', [request.id, request.secret]);
      assert.equal((await rpc('complete_member_account_merge($1,$2,$3)', [request.id, request.secret, uid(1152)])).success, true);
      assert.equal(await owner(phone(1151)), uid(1152));
      assert.equal(Number((await db.query('select count(*) from orders where user_id=$1', [uid(1152)])).rows[0].count), 2);
      // 빈 계정은 통합에 끌려 들어가지 않고 그대로 남는다.
      assert.equal(Number((await db.query('select count(*) from member_account_merges where source_user_id=$1', [uid(1153)])).rows[0].count), 0);
    });
    await t.test('이력으로 치는 것과 치지 않는 것', async () => {
      let n = 1200;
      const pair = async () => { n += 2; await account(n, 'cl', { number: phone(n) }); await account(n + 1, 'ho', { number: phone(n) }); return [n, n + 1]; };
      await db.query("insert into coupons(title,discount_type,discount_value,campaign_key) values('테스트','fixed',1000,'empty-legacy-test')");
      const history = {
        orders: h => db.query('insert into orders(user_id) values($1)', [uid(h)]),
        pg_checkout_sessions: h => db.query("insert into pg_checkout_sessions(user_id,status) values($1,'expired')", [uid(h)]),
        pickup_requests: h => db.query('insert into pickup_requests(user_id) values($1)', [uid(h)]),
        shipments: h => db.query('insert into shipments(user_id) values($1)', [uid(h)]),
        settlements: h => db.query('insert into settlements(seller_user_id,net_amount) values($1,1000)', [uid(h)]),
        point_lots: h => db.query("insert into point_lots(user_id,remaining,expires_at) values($1,0,now()-interval '1 day')", [uid(h)]),
        point_transactions: h => db.query('insert into point_transactions(user_id,amount) values($1,-100)', [uid(h)]),
        reviews: h => db.query('insert into reviews(user_id) values($1)', [uid(h)]),
        legacy_reviews: h => db.query('insert into legacy_reviews(user_id) values($1)', [uid(h)]),
        used_coupon: h => db.query("insert into member_coupons(coupon_id,user_id,used_at,status) select id,$1,now(),'used' from coupons where campaign_key='empty-legacy-test'", [uid(h)]),
      };
      for (const [name, add] of Object.entries(history)) {
        const [claimant, holder] = await pair(); await add(holder);
        assert.equal((await otp(claimant, phone(claimant))).status, 'merge_required', name);
      }
      const notHistory = {
        cart_items: h => db.query('insert into cart_items(user_id,book_id,quantity) values($1,1,1)', [uid(h)]),
        wishlist_items: h => db.query('insert into wishlist_items(user_id,product_id) values($1,1)', [uid(h)]),
        member_shipping_addresses: h => db.query("insert into member_shipping_addresses(user_id,is_default,address) values($1,true,'주소')", [uid(h)]),
        member_settlement_accounts: h => db.query("insert into member_settlement_accounts(user_id,is_default,account_number) values($1,true,'0')", [uid(h)]),
        unused_coupon: h => db.query("insert into member_coupons(coupon_id,user_id) select id,$1 from coupons where campaign_key='empty-legacy-test'", [uid(h)]),
        legacy_sixshop_customers: h => db.query('insert into legacy_sixshop_customers(backfilled_user_id) values($1)', [uid(h)]),
      };
      for (const [name, add] of Object.entries(notHistory)) {
        const [claimant, holder] = await pair(); await add(holder);
        assert.equal((await otp(claimant, phone(claimant))).status, 'verified', name);
      }
    });
    await t.test('관리자 겸용 계정의 번호 기록은 이력이 없어도 계속 막는다', async () => {
      await account(1161, 'ad', { number: phone(1161), admin: true, provider: 'google' }); await account(1162, 'cl', { number: phone(1161) });
      assert.equal((await otp(1162, phone(1161))).status, 'existing_account');
      assert.deepEqual((await identity()).existing_accounts, [hint('ad', 'google')]);
      assert.equal(await owner(phone(1161)), undefined);
    });
    await t.test('신규 가입·전환 뒤 계정·프로필 없는 과거 기록은 빈 계정에도 그대로 막힌다', async () => {
      await account(1171, 'e1', { number: phone(1171) }); await account(1172, 'e2', { number: phone(1171), provider: 'kakao' });
      assert.equal(await rpc('public._member_phone_conflicts(null,$1)', [phone(1171)]), true);
      for (const [n, options] of [[1173, { legacy: false, profile: false }], [1174, { profile: false }]]) {
        await account(n, 'nw', options);
        assert.equal((await otp(n, phone(1171))).status, 'existing_account');
        // 전부 빈 계정이면 어느 쪽으로 로그인해도 되므로 모두 안내한다.
        assert.deepEqual((await identity()).existing_accounts, [hint('e1'), hint('e2', 'kakao')]);
        assert.equal(Number((await db.query('select count(*) from member_profiles where user_id=$1', [uid(n)])).rows[0].count), 0);
      }
      assert.equal(await owner(phone(1171)), undefined);
    });
    await t.test('신규 계정에는 이력 있는 계정만 안내한다', async () => {
      await account(1181, 'e1', { number: phone(1181) });
      await account(1182, 'us', { number: phone(1181), provider: 'kakao' }); await order(1182);
      await account(1183, 'nw', { legacy: false, profile: false });
      assert.equal((await otp(1183, phone(1181))).status, 'existing_account');
      assert.deepEqual((await identity()).existing_accounts, [hint('us', 'kakao')]);
      await db.query("update member_phone_proofs set expires_at=now()-interval '1 second' where user_id=$1", [uid(1183)]);
      assert.deepEqual((await identity()).existing_accounts, [hint('us', 'kakao')]);
    });
    await t.test('새 비공개 함수는 일반 사용자가 실행할 수 없다', async () => {
      for (const role of ['anon', 'authenticated', 'public']) {
        for (const func of ['_member_is_legacy_member(uuid)', '_member_phone_record_holds(uuid)', '_member_phone_conflicts(uuid,text)',
          '_member_phone_merge_candidates(uuid,text)', '_member_existing_phone_account_ids(text,uuid)']) {
          assert.equal(await rpc("has_function_privilege($1,$2,'execute')", [role, `public.${func}`]), false, `${role} ${func}`);
        }
      }
    });
  } finally { await db.close(); }
});
