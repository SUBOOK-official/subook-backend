import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeIdentityDb, uid, migration } from './helpers/member-identity-db.js';

const hash=(value)=>createHash('sha256').update(value).digest('hex');
test('이메일 필수·번호 인증 후 회원 등록·카카오 인증 번호 경로',async(t)=>{
  const db=await makeIdentityDb();
  const rpc=async(sql,args=[]) => (await db.query(`select ${sql} result`,args)).rows[0].result;
  const as=(n)=>db.query("select set_config('test.uid',$1,false)",[uid(n)]);
  const account=async(n,provider='email',metadata={})=>db.query(`insert into auth.users(id,email,raw_app_meta_data,raw_user_meta_data,email_confirmed_at)
    values($1,$2,jsonb_build_object('provider',$3::text),$4,now())`,[uid(n),`signup${n}@example.invalid`,provider,JSON.stringify(metadata)]);
  try{
    await db.exec('create role supabase_auth_admin');
    await db.exec(migration('20261001080300_restore_email_signup_phone_verification'));
    await t.test('번호 단독 가입·증명 없는 이메일 가입은 생성 전 거절',async()=>{
      assert.ok((await rpc('before_member_user_created($1)',[{user:{phone:'821011111111',app_metadata:{provider:'phone'}}}])).error);
      assert.ok((await rpc('before_member_user_created($1)',[{user:{email:'a@example.invalid',app_metadata:{provider:'email'},user_metadata:{phone:'01011111111'}}}])).error);
    });
    await t.test('이메일에 묶인 SMS 증명·오입력 누적·일회성 사용',async()=>{
      const secret='a'.repeat(64);const id=uid(500);
      assert.equal((await rpc('reserve_signup_phone_challenge($1,$2,$3,$4,$5,$6)',[id,'signup501@example.invalid','01011115555',hash(secret),hash('123456'),hash('ip')])).success,true);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)',[id,hash(secret),hash('999999')])).success,false);
      assert.equal((await db.query('select attempt_count from member_signup_phone_challenges')).rows[0].attempt_count,1);
      assert.equal((await rpc('verify_signup_phone_challenge($1,$2,$3)',[id,hash(secret),hash('123456')])).success,true);
      const metadata={signup_phone_id:id,signup_phone_secret:secret};
      const hook=email=>rpc('before_member_user_created($1)',[{user:{email,app_metadata:{provider:'email'},user_metadata:metadata}}]);
      assert.ok((await hook('wrong@example.invalid')).error);
      assert.deepEqual(await hook('signup501@example.invalid'),{});
      await account(501,'email',metadata);await as(501);
      assert.equal((await rpc('get_my_member_identity()')).status,'verified');
      assert.equal((await db.query('select terms_agreed_at from member_profiles where user_id=$1',[uid(501)])).rows[0].terms_agreed_at,null);
      assert.ok((await hook('signup501@example.invalid')).error);
      await db.query("update auth.users set encrypted_password='fixture-hash' where id=$1",[uid(501)]);
      await rpc("complete_oauth_signup(false,'가입자',null)");
      assert.equal(await rpc('member_identity_is_ready()'),true);
    });
    await t.test('카카오/구글 임시 인증만으로 회원을 만들지 않는다',async()=>{
      await account(502,'kakao',{phone:'01011116666',terms_agreed_at:new Date().toISOString()});await as(502);
      assert.equal(Number((await db.query('select count(*) from member_profiles where user_id=$1',[uid(502)])).rows[0].count),0);
      assert.equal(await rpc('member_identity_is_ready()'),false);
      const proved=await rpc('claim_kakao_member_phone($1,$2)',[uid(502),'01011116666']);
      assert.equal(proved.status,'verified');
      await rpc("complete_oauth_signup(false,'카카오회원',null)");
      await db.exec('set role authenticated');
      await assert.rejects(rpc('claim_kakao_member_phone($1,$2)',[uid(502),'01099999999']),/permission denied/);
      await db.exec('reset role');
    });
    await t.test('인증된 중복 번호도 대표 선택과 기존 계정 증명 필요',async()=>{
      await account(503,'google');await as(503);
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(503),'01011116666'])).status,'merge_required');
      assert.equal(await rpc('member_identity_is_ready()'),false);
      const view=await rpc('start_member_account_merge()');
      assert.equal(view.accounts.length,2);
      assert.equal(view.accounts.filter(x=>x.verified).length,1);
      await db.query("insert into orders(user_id,total_amount) values($1,30000)",[uid(502)]);
      await as(502);
      await db.query("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({amr:[{method:'oauth',timestamp:Math.floor(Date.now()/1000)+1}]})]);
      await rpc('prove_member_account_merge($1,$2)',[view.id,view.secret]);
      await rpc('complete_member_account_merge($1,$2,$3)',[view.id,view.secret,uid(502)]);
      assert.equal((await db.query('select total_amount from orders where user_id=$1',[uid(502)])).rows[0].total_amount,30000);
      await as(503);assert.equal(await rpc('member_identity_is_ready()'),false);
    });
    await t.test('이메일·번호·약관을 모두 마친 첫 친구에게만 양쪽 쿠폰 동시 지급',async()=>{
      await as(501);const invitation=await rpc('get_my_signup_referral()');
      await account(505,'google');await as(505);
      await rpc('claim_kakao_member_phone($1,$2)',[uid(505),'01011118888']);
      await rpc('attach_signup_referral($1)',[invitation.code]);
      assert.equal(Number((await db.query('select count(*) from member_coupons where user_id=$1',[uid(505)])).rows[0].count),0);
      await rpc("complete_oauth_signup(false,'친구',null)");
      await rpc('complete_signup_referral()');
      const coupons=(await db.query(`select c.campaign_key,mc.issued_at,mc.expires_at from member_coupons mc join coupons c on c.id=mc.coupon_id where c.campaign_key like 'signup_referral_%'`)).rows;
      assert.equal(coupons.length,2);assert.equal(+coupons[0].issued_at,+coupons[1].issued_at);
      assert.equal((new Date(coupons[0].expires_at)-new Date(coupons[0].issued_at))/86400000,30);
      assert.equal((await rpc('get_signup_referral_offer($1)',[invitation.code])).code_expired,true);
    });
    await t.test('이메일 없는 기존 계정은 보존하되 가입완료와 이용 차단',async()=>{
      await db.query("insert into auth.users(id,raw_app_meta_data,phone,phone_confirmed_at) values($1,'{\"provider\":\"phone\"}','821011117777',now())",[uid(504)]);
      await as(504);
      assert.equal(await rpc('member_identity_is_ready()'),false);
      await assert.rejects(rpc("complete_oauth_signup(false,'회원',null)"),/이메일/);
      const policy=await rpc('get_member_identity_policy()');
      assert.equal(policy.phone_signup_enabled,false);assert.equal(policy.legacy_phone_login_enabled,true);
    });
  }finally{await db.close();}
});
