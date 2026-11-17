// 수북 회원 로그인 수단에 Apple 추가: 가입 전 확인 함수가 Apple을 카카오·구글처럼 받고,
// Apple 가입자도 휴대폰 인증을 마쳐야 회원이 되는지 PGlite에서 실제로 실행해 확인한다. 운영 DB에는 접속하지 않는다.
import test from 'node:test';
import assert from 'node:assert/strict';
import {makeIdentityDb,uid,migration} from './helpers/member-identity-db.js';

test('Apple 가입: 가입 전 확인 통과, 프로필은 휴대폰 인증 뒤에만 생긴다',async t=>{
  const db=await makeIdentityDb();
  const rpc=async(sql,args=[])=>(await db.query(`select ${sql} result`,args)).rows[0].result;
  const as=n=>db.query("select set_config('test.uid',$1,false)",[uid(n)]);
  const hook=user=>rpc('before_member_user_created($1)',[{user}]);
  const hasProfile=async n=>Number((await db.query('select count(*) from member_profiles where user_id=$1',[uid(n)])).rows[0].count)>0;
  try{
    await db.exec('create role supabase_auth_admin');
    await db.exec(migration('20261001080300_restore_email_signup_phone_verification'));
    await db.exec(migration('20261001091226_reject_duplicate_phone_signup'));
    await db.exec(migration('20261001104338_align_phone_merge_eligibility'));
    await db.exec(migration('20261001110924_verified_phone_account_hints'));

    await t.test('이 변경 전에는 Apple 가입이 거절된다',async()=>{
      assert.ok((await hook({email:'a@privaterelay.appleid.com',app_metadata:{provider:'apple'}})).error);
    });

    await db.exec(migration('20261117180240_allow_apple_member_login'));

    await t.test('Apple·카카오·구글은 통과, 이메일 없는 Apple과 증명 없는 이메일 가입은 거절',async()=>{
      assert.deepEqual(await hook({email:'a@privaterelay.appleid.com',app_metadata:{provider:'apple'}}),{});
      assert.deepEqual(await hook({email:'k@example.invalid',app_metadata:{provider:'kakao'}}),{});
      assert.deepEqual(await hook({email:'g@example.invalid',app_metadata:{provider:'google'}}),{});
      assert.match((await hook({app_metadata:{provider:'apple'}})).error.message,/이메일이 있는 계정/);
      assert.ok((await hook({email:'e@example.invalid',app_metadata:{provider:'email'}})).error);
      assert.ok((await hook({email:'n@example.invalid',app_metadata:{provider:'naver'}})).error);
    });

    await t.test('Apple 가입자는 휴대폰 인증을 마쳐야 회원 프로필이 생긴다',async()=>{
      await db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values($1,$2,now(),'{"provider":"apple"}')`,[uid(701),'apple701@privaterelay.appleid.com']);
      assert.equal(await hasProfile(701),false);
      // 카카오 번호 확인과 같은 서버 전용 경로로 인증된 번호를 기록한다(문자 인증도 끝에는 같은 함수로 모인다)
      assert.equal((await rpc('claim_kakao_member_phone($1,$2)',[uid(701),'01033337001'])).status,'verified');
      assert.equal(await hasProfile(701),true);
      await as(701);
      await rpc("complete_oauth_signup(false,'애플회원',null)");
      const row=(await db.query('select name,terms_agreed_at is not null as agreed from member_profiles where user_id=$1',[uid(701)])).rows[0];
      assert.equal(row.name,'애플회원');
      assert.equal(row.agreed,true);
    });
  }finally{
    await db.close();
  }
});
