// 관리자 회원 화면이 읽는 "회원이 지금 로그인할 수 있는 상태인지"(get_admin_member_login_state)를 PGlite에서 실제로 실행해 확인한다.
// 회원 본인이 보는 get_my_member_identity·get_current_auth_account_role과 같은 답을 주는지, 관리자만 부를 수 있는지 본다.
// 운영 DB에는 접속하지 않는다.
import test from 'node:test';
import assert from 'node:assert/strict';
import {makeIdentityDb,uid,migration} from './helpers/member-identity-db.js';

test('관리자 회원 화면: 회원의 계정 상태와 휴대폰 인증 상태',async t=>{
  const db=await makeIdentityDb();
  const rpc=async(sql,args=[])=>(await db.query(`select ${sql} result`,args)).rows[0].result;
  const as=n=>db.query("select set_config('test.uid',$1,false)",[n?uid(n):'']);
  const admin=on=>db.query("select set_config('test.admin',$1,false)",[on?'on':'']);
  const add=(n)=>db.query(`insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data) values($1,$2,now(),'{"provider":"email"}')`,
    [uid(n),`member${n}@example.invalid`]);
  const state=n=>rpc('public.get_admin_member_login_state($1)',[uid(n)]);
  try{
    // 이 시험에서는 설정값으로 관리자 여부를 바꾼다(운영의 is_admin_user는 admin_users와 역할을 본다)
    await db.exec("create or replace function public.is_admin_user() returns boolean language sql as $$ select current_setting('test.admin',true)='on' $$");
    await db.exec(migration('20261122081342_admin_member_login_state'));

    for(const n of [801,802,803,804,805,806]) await add(n);
    // 801: 휴대폰 인증까지 마친 회원(문자·카카오 인증이 끝에 모이는 서버 전용 함수로 번호를 귀속한다)
    assert.equal((await rpc('public._claim_member_phone($1,$2)',[uid(801),'01055558801'])).status,'verified');
    // 802: 인증 전. 803: 801로 통합된 계정
    await db.query('insert into public.member_account_merges(source_user_id,target_user_id) values($1,$2)',[uid(803),uid(801)]);
    // 804: 차단, 805: 탈퇴 대기, 806: 탈퇴 완료(탈퇴가 차단보다 앞선다)
    await db.query('update public.member_profiles set is_blocked=true where user_id=any($1)',[[uid(804),uid(806)]]);
    await db.query('update public.member_profiles set withdrawal_requested_at=now() where user_id=any($1)',[[uid(805),uid(806)]]);
    await db.query('update public.member_profiles set personal_data_erased_at=now() where user_id=$1',[uid(806)]);

    await t.test('관리자가 아니면 부를 수 없다',async()=>{
      await admin(false); await as(802);
      await assert.rejects(()=>state(801),/Admin access required/);
      const grants=(await db.query(`select grantee from information_schema.routine_privileges
        where routine_schema='public' and routine_name='get_admin_member_login_state' order by grantee`)).rows.map(r=>r.grantee);
      assert.ok(grants.includes('authenticated'));
      assert.ok(!grants.includes('anon'));
      assert.ok(!grants.includes('PUBLIC'));
    });

    await t.test('휴대폰 인증: 인증됨·인증 전·통합됨을 회원 본인이 보는 상태와 같게 돌려준다',async()=>{
      await admin(true);
      const verified=await state(801);
      assert.equal(verified.identity_status,'verified');
      assert.equal(verified.identity_enabled,true);
      assert.equal(verified.account_status,'active');
      assert.ok(verified.verified_at);
      assert.equal(verified.merged_into,null);
      assert.equal('phone' in verified,false);

      const unverified=await state(802);
      assert.equal(unverified.identity_status,'unverified');
      assert.equal(unverified.verified_at,null);

      const merged=await state(803);
      assert.equal(merged.identity_status,'merged');
      assert.equal(merged.merged_into,uid(801));

      // 회원 본인이 보는 값과 견준다
      for(const [n,status] of [[801,'verified'],[802,'unverified'],[803,'merged']]){
        await as(n);
        assert.equal((await rpc('public.get_my_member_identity()')).status,status);
      }
      await assert.rejects(()=>rpc('public.get_admin_member_login_state(null)'),/Member id is required/);
    });

    await t.test('계정 상태: 차단·탈퇴 대기·탈퇴 완료, 회원 프로필이 없으면 missing',async()=>{
      await admin(true);
      assert.equal((await state(804)).account_status,'blocked');
      assert.equal((await state(805)).account_status,'withdrawal_pending');
      assert.equal((await state(806)).account_status,'withdrawn');
      assert.equal((await state(899)).account_status,'missing');
    });

    await t.test('1번호 1계정 정책이 꺼져 있으면 identity_enabled=false로 알려 준다',async()=>{
      await admin(true);
      await db.exec('update public.member_identity_policy set enabled=false');
      assert.equal((await state(802)).identity_enabled,false);
    });
  }finally{
    await db.close();
  }
});
