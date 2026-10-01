import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {makeIdentityDb,uid,migration} from './helpers/member-identity-db.js';
const hash=value=>createHash('sha256').update(value).digest('hex');

test('신규 중복 번호 가입 차단과 기존 계정 로그인 안내',async t=>{
  const db=await makeIdentityDb();
  const rpc=async(sql,args=[])=>(await db.query(`select ${sql} result`,args)).rows[0].result;
  const as=n=>db.query("select set_config('test.uid',$1,false)",[uid(n)]);
  const account=(n,provider='google')=>db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values($1,$2,now(),jsonb_build_object('provider',$3::text))`,[uid(n),`new${n}@example.invalid`,provider]);
  const hasProfile=async n=>Number((await db.query('select count(*) from member_profiles where user_id=$1',[uid(n)])).rows[0].count)>0;
  try{
    await db.exec('create role supabase_auth_admin');
    await db.exec(migration('20261001080300_restore_email_signup_phone_verification'));
    await db.exec(migration('20261001091226_reject_duplicate_phone_signup'));
    await t.test('이메일과 카카오 인증 번호로 회원 생성·같은 계정 재로그인 허용',async()=>{
      await account(601,'kakao');assert.equal(await hasProfile(601),false);
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(601),'01033330001'])).status,'verified');
      await as(601);await rpc("complete_oauth_signup(false,'카카오회원',null)");
      assert.equal(await hasProfile(601),true);
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(601),'01033330001'])).status,'verified');
      assert.equal(await rpc('member_identity_is_ready()'),true);
    });
    await t.test('다른 이메일의 구글 가입+같은 번호 SMS 인증은 기존 로그인 안내·회원 미생성',async()=>{
      await account(602);await as(602);
      await db.query(`insert into phone_verification_codes(user_id,phone,code_hash,expires_at) values($1,'01033330001',$2,now()+interval '5 minutes')`,[uid(602),hash('123456'+uid(602))]);
      assert.equal((await rpc("verify_phone_otp('123456')")).status,'existing_account');
      assert.equal(await hasProfile(602),false);
      assert.equal(await rpc('member_identity_is_ready()'),false);
      const identity=await rpc('get_my_member_identity()');
      assert.equal(identity.status,'existing_account');assert.equal(identity.can_merge,false);
      await assert.rejects(rpc('start_member_account_merge()'),/기존 계정으로 로그인/);
      await assert.rejects(rpc("complete_oauth_signup(false,'중복',null)"),/휴대폰 인증/);
      assert.equal(Number((await db.query('select count(*) from member_coupons where user_id=$1',[uid(602)])).rows[0].count),0);
    });
    await t.test('다른 카카오 계정이 같은 번호를 제공해도 기존 로그인 안내',async()=>{
      await account(603,'kakao');await as(603);
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(603),'01033330001'])).status,'existing_account');
      assert.equal(await hasProfile(603),false);
      assert.equal((await rpc('get_my_member_identity()')).status,'existing_account');
    });
    await t.test('이메일 가입의 번호 증명은 중복이면 Auth 생성 전에 차단',async()=>{
      const id=uid(604),secret='a'.repeat(64),email='new604@example.invalid';
      await rpc('reserve_signup_phone_challenge($1,$2,$3,$4,$5,$6)',[id,email,'01033330001',hash(secret),hash('123456'),hash('ip')]);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)',[id,hash(secret),hash('123456')])).status,'existing_account');
      const metadata={signup_phone_id:id,signup_phone_secret:secret};
      assert.match((await rpc('before_member_user_created($1)',[{user:{email,app_metadata:{provider:'email'},user_metadata:metadata}}])).error.message,/기존 계정으로 로그인/);
      await assert.rejects(db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data) values($1,$2,now(),'{"provider":"email"}',$3)`,[uid(604),email,JSON.stringify(metadata)]),/기존 계정으로 로그인/);
      assert.equal(Number((await db.query('select count(*) from auth.users where id=$1',[uid(604)])).rows[0].count),0);
      assert.equal((await db.query('select claimed_at from member_signup_phone_challenges where id=$1',[id])).rows[0].claimed_at,null);
    });
    await t.test('SMS 확인 후 다른 계정이 먼저 번호를 선점해도 원자적으로 거부',async()=>{
      const id=uid(606),secret='b'.repeat(64),email='new606@example.invalid';
      await rpc('reserve_signup_phone_challenge($1,$2,$3,$4,$5,$6)',[id,email,'01033330002',hash(secret),hash('123456'),hash('ip')]);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)',[id,hash(secret),hash('123456')])).status,'verified');
      await account(605);await rpc('claim_kakao_member_phone($1,$2)',[uid(605),'01033330002']);
      const metadata={signup_phone_id:id,signup_phone_secret:secret};
      await assert.rejects(db.query(`insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data) values($1,$2,'{"provider":"email"}',$3)`,[uid(606),email,JSON.stringify(metadata)]),/기존 계정으로 로그인/);
      assert.equal(await hasProfile(606),false);
    });
    await t.test('전환 전 기존 중복 계정만 소유 증명 후 대표 선택 가능',async()=>{
      for(const n of [610,611]){
        await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data,created_at) values($1,$2,now(),'{"provider":"email"}',now()-interval '1 day')`,[uid(n),`legacy${n}@example.invalid`]);
        await db.query(`insert into member_profiles(user_id,email,phone,terms_agreed_at,privacy_agreed_at) values($1,$2,'01033330003',now(),now())`,[uid(n),`legacy${n}@example.invalid`]);
        await db.query("insert into member_legacy_phone_accounts(user_id,phone) values($1,'01033330003')",[uid(n)]);
      }
      await as(610);assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(610),'01033330003'])).status,'merge_required');
      const merge=await rpc('start_member_account_merge()');assert.equal(merge.accounts.length,2);
      await as(611);await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({amr:[{method:'password',timestamp:Math.floor(Date.now()/1000)+1}]})]);
      await rpc('prove_member_account_merge($1,$2)',[merge.id,merge.secret]);
      assert.equal((await rpc('complete_member_account_merge($1,$2,$3)',[merge.id,merge.secret,uid(611)])).success,true);
    });
    await t.test('중복 안내 후 다른 신규 번호로 정상 가입 가능',async()=>{
      await as(602);assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(602),'01033330004'])).status,'verified');
      assert.equal(await hasProfile(602),true);await rpc("complete_oauth_signup(false,'구글회원',null)");
      assert.equal(await rpc('member_identity_is_ready()'),true);
    });
    await t.test('정상 신규 친구 가입의 쿠폰 동시 지급과 링크 1회 유지',async()=>{
      await as(601);const invite=await rpc('get_my_signup_referral()');
      await account(620);await as(620);await rpc('claim_kakao_member_phone($1,$2)',[uid(620),'01033330005']);
      await rpc('attach_signup_referral($1)',[invite.code]);await rpc("complete_oauth_signup(false,'초대친구',null)");
      assert.equal((await rpc('complete_signup_referral()')).status,'rewarded');
      const rows=(await db.query(`select mc.issued_at from member_coupons mc join coupons c on c.id=mc.coupon_id where c.campaign_key in ('signup_referral_inviter','signup_referral_friend')`)).rows;
      assert.equal(rows.length,2);assert.equal(+rows[0].issued_at,+rows[1].issued_at);
      assert.equal((await rpc('get_signup_referral_offer($1)',[invite.code])).code_expired,true);
    });
    await t.test('일반 회원은 전화번호 단독 로그인을 사용할 수 없다',async()=>{
      await db.query("update auth.users set phone='821033330001',phone_confirmed_at=now() where id=$1",[uid(601)]);
      assert.equal((await rpc('reserve_member_auth_sms_hook($1,$2)',['01033330001','phone-login-disallowed'])).success,false);
    });
  }finally{await db.close();}
});
