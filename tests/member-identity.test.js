import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makeIdentityDb, uid } from './helpers/member-identity-db.js';

test('휴대폰 정책·인증·대표 계정 통합', async (t) => {
  const db = await makeIdentityDb();
  const as = (n) => db.query("select set_config('test.uid',$1,false)", [n ? uid(n) : '']);
  const rpc = async (sql, args = []) => (await db.query(`select ${sql} as result`, args)).rows[0].result;
  const add = async (n, phone = null, provider = 'email') => {
    await as(null);
    await db.query(`insert into auth.users(id,email,email_confirmed_at,encrypted_password,raw_app_meta_data,raw_user_meta_data)
      values($1,$2,case when $4='email' then now() end,'password',jsonb_build_object('provider',$4::text),
        jsonb_build_object('phone',$3::text,'terms_agreed_at',now()::text,'privacy_agreed_at',now()::text))`,
    [uid(n), provider === 'phone' ? null : `member${n}@example.invalid`, phone, provider]);
  };
  const otp = async (n, phone, code = '123456') => {
    await db.query(`insert into public.phone_verification_codes(user_id,phone,code_hash,expires_at)
      values($1,$2,$3,now()+interval '5 minutes')`, [uid(n),phone,createHash('sha256').update(code+uid(n)).digest('hex')]);
    await as(n);
    return rpc('public.verify_phone_otp($1)',[code]);
  };
  try {
    await t.test('인증 전 접근 차단·확인 없는 쿠폰 발급 방지', async () => {
      await db.exec("insert into coupons(title,issue_on_signup,valid_days) values('가입 혜택',true,30)");
      await add(1); await as(1);
      assert.equal((await rpc('public.get_my_member_identity()')).status,'unverified');
      assert.equal(await rpc('public.member_identity_is_ready()'),false);
      assert.equal(Number((await db.query('select count(*) from member_coupons')).rows[0].count),0);
      await db.exec("select set_config('request.path','/rpc/create_order',false)");
      await assert.rejects(rpc('public.enforce_member_identity_request()'),/휴대폰 인증/);
      await db.exec("select set_config('request.path','/rpc/get_my_member_identity',false)");
      await rpc('public.enforce_member_identity_request()');
    });
    await t.test('틀린 OTP 5회가 롤백되지 않으며 최신 코드만 사용 가능', async () => {
      await db.query(`insert into phone_verification_codes(user_id,phone,code_hash,expires_at) values($1,'01011111111',$2,now()+interval '5 minutes')`,
        [uid(1),createHash('sha256').update('123456'+uid(1)).digest('hex')]);
      for (let i=0;i<5;i++) assert.equal((await rpc('public.verify_phone_otp($1)',['999999'])).success,false);
      assert.equal((await rpc('public.verify_phone_otp($1)',['123456'])).success,false);
      assert.equal((await db.query('select attempt_count from phone_verification_codes limit 1')).rows[0].attempt_count,5);
      assert.equal((await otp(1,'01011111111')).status,'verified');
      assert.equal((await rpc('public.verify_phone_otp($1)',['123456'])).success,false);
      assert.equal(await rpc('public.member_identity_is_ready()'),true);
      assert.equal(Number((await db.query('select count(*) from member_coupons where user_id=$1',[uid(1)])).rows[0].count),1);
    });
    await t.test('인증 번호의 중복 계정·임의 변경·직접 필드 변조 차단', async () => {
      await add(2,'01011111111');
      assert.equal((await otp(2,'01011111111')).status,'merge_required');
      assert.equal(await rpc('public.member_identity_is_ready()'),false);
      await as(1);
      assert.equal((await otp(1,'01022222222')).status,'phone_change_required');
      await db.exec('grant select,update on member_profiles to authenticated; set role authenticated');
      await assert.rejects(db.query('update member_profiles set verified_phone=$1 where user_id=$2',['01099999999',uid(1)]),/휴대폰 인증/);
      await db.exec('reset role');
      await assert.rejects(db.query("update auth.users set phone='821022222222',phone_confirmed_at=now() where id=$1",[uid(1)]),/인증 번호 변경/);
      await db.query('update member_profiles set is_blocked=true where user_id=$1',[uid(1)]);
      await assert.rejects(rpc('public.get_member_phone_binding($1)',[uid(1)]),/이용할 수 없는 계정/);
      await db.query('update member_profiles set is_blocked=false where user_id=$1',[uid(1)]);
    });
    await t.test('SMS 예약의 재전송 한도와 hook 재시도 멱등성', async () => {
      assert.equal((await rpc("public.reserve_member_auth_sms_hook('01033333333','hook-1')")).success,true);
      assert.equal((await rpc("public.reserve_member_auth_sms_hook('01033333333','hook-1')")).sent,false);
      assert.equal((await rpc("public.reserve_member_auth_sms_hook('01033333333','hook-2')")).success,false);
      await rpc("public.complete_member_auth_sms_hook('hook-1')");
      assert.equal((await rpc("public.reserve_member_auth_sms_hook('01033333333','hook-1')")).sent,true);
      await db.exec('set role authenticated');
      await assert.rejects(rpc("public.reserve_member_auth_sms('01033333333')"),/permission denied/);
      await db.exec('reset role');
    });
    await t.test('대표 선택 통합: 소유 증명·다른 계정 정보 보호·원자성·자산 보존', async () => {
      await add(10,'01044444444'); await add(11,'01044444444'); await add(12);
      await db.query("insert into member_legacy_phone_accounts(user_id,phone) values($1,'01044444444'),($2,'01044444444')",[uid(10),uid(11)]);
      await db.query("insert into orders(user_id,total_amount) values($1,30000),($2,40000)",[uid(10),uid(11)]);
      await db.query("insert into point_lots(user_id,remaining,expires_at) values($1,1000,now()+interval '30 days'),($2,2000,now()+interval '30 days')",[uid(10),uid(11)]);
      await db.query("insert into settlements(seller_user_id,net_amount,bank_name,account_number) values($1,12345,'은행','1234')",[uid(10)]);
      await db.query("insert into cart_items(user_id,book_id,quantity) values($1,1,1),($2,1,1),($1,2,1)",[uid(10),uid(11)]);
      await db.query("insert into member_shipping_addresses(user_id,is_default,address) values($1,true,'A'),($2,true,'B')",[uid(10),uid(11)]);
      await db.query("insert into member_settlement_accounts(user_id,is_default,account_number) values($1,true,'A'),($2,true,'B')",[uid(10),uid(11)]);
      const couponId=(await db.query("insert into coupons(title) values('중복 혜택') returning id")).rows[0].id;
      await db.query("insert into member_coupons(coupon_id,user_id,used_at,status) values($1,$2,now(),'used'),($1,$3,null,'available')",[couponId,uid(10),uid(11)]);
      assert.equal((await otp(10,'01044444444')).status,'merge_required');
      const request=await rpc('public.start_member_account_merge()');
      assert.equal(request.accounts.find(x=>x.id===uid(11)).orders,null);
      assert.match(request.accounts.find(x=>x.id===uid(11)).email,/\*\*\*/);
      await assert.rejects(rpc('public.complete_member_account_merge($1,$2,$3)',[request.id,request.secret,uid(10)]),/기존 계정/);
      await as(12);
      await assert.rejects(rpc('public.get_member_account_merge($1,$2)',[request.id,request.secret]),/확인할 수 없습니다/);
      await as(11);
      await assert.rejects(rpc('public.prove_member_account_merge($1,$2)',[request.id,'invalid']),/확인할 수 없습니다/);
      await assert.rejects(rpc('public.prove_member_account_merge($1,$2)',[request.id,request.secret]),/다시 로그인/);
      await db.query('update auth.users set last_sign_in_at=now() where id=$1',[uid(11)]);
      await db.exec("select set_config('request.jwt.claims',jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','token_refresh','timestamp',floor(extract(epoch from now())))))::text,false)");
      await assert.rejects(rpc('public.prove_member_account_merge($1,$2)',[request.id,request.secret]),/다시 로그인/);
      await db.exec("select set_config('request.jwt.claims',jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','password','timestamp',floor(extract(epoch from now()-interval '1 day')))))::text,false)");
      await assert.rejects(rpc('public.prove_member_account_merge($1,$2)',[request.id,request.secret]),/다시 로그인/);
      await db.exec("select set_config('request.jwt.claims',jsonb_build_object('amr',jsonb_build_array(jsonb_build_object('method','password','timestamp',floor(extract(epoch from now())))))::text,false)");
      const proven=await rpc('public.prove_member_account_merge($1,$2)',[request.id,request.secret]);
      assert.equal(proven.accounts.find(x=>x.id===uid(11)).orders,1);
      await assert.rejects(rpc('public.complete_member_account_merge($1,$2,$3)',[request.id,request.secret,uid(10)]),/대표 계정으로 로그인/);
      const complete=()=>rpc('public.complete_member_account_merge($1,$2,$3)',[request.id,request.secret,uid(11)]);
      await db.query("insert into pg_checkout_sessions(user_id,status) values($1,'created')",[uid(10)]);
      await assert.rejects(complete(),/최대 24시간/);
      await db.exec("update pg_checkout_sessions set created_at=now()-interval '25 hours'");
      await db.exec(`create function fail_merge() returns trigger language plpgsql as $$ begin raise exception 'injected failure'; end $$;
        create trigger fail_merge before update on orders for each row execute function fail_merge()`);
      await assert.rejects(complete(),/injected failure/);
      assert.equal(Number((await db.query('select count(*) from member_account_merges where source_user_id=$1',[uid(10)])).rows[0].count),0);
      assert.equal(Number((await db.query('select count(*) from member_merge_row_audit where request_id=$1',[request.id])).rows[0].count),0);
      await db.exec('drop trigger fail_merge on orders');
      assert.equal((await complete()).success,true);
      assert.equal((await complete()).success,true);
      assert.equal(Number((await db.query('select sum(total_amount) from orders where user_id=$1',[uid(11)])).rows[0].sum),70000);
      assert.equal(Number((await db.query('select sum(remaining) from point_lots where user_id=$1',[uid(11)])).rows[0].sum),3000);
      assert.equal((await db.query('select net_amount,account_number from settlements where seller_user_id=$1',[uid(11)])).rows[0].net_amount,12345);
      assert.equal((await db.query('select status from member_coupons where user_id=$1 and coupon_id=$2',[uid(11),couponId])).rows[0].status,'expired');
      assert.equal((await db.query('select status from member_coupons where user_id=$1 and coupon_id=$2',[uid(10),couponId])).rows[0].status,'used');
      assert.equal(Number((await db.query('select count(*) from cart_items where user_id=$1',[uid(11)])).rows[0].count),2);
      assert.equal((await rpc('public.get_my_member_identity()')).status,'verified');
      await as(10);
      assert.equal((await rpc('public.get_my_member_identity()')).status,'merged');
      await assert.rejects(rpc('public.assert_member_not_blocked()'),/통합된 계정/);
      await assert.rejects(db.query('insert into orders(user_id,total_amount) values($1,1)',[uid(10)]),/대표 계정/);
      await db.exec("select set_config('test.role','service_role',false)");
      await db.query('insert into orders(user_id,total_amount) values($1,1)',[uid(10)]);
      assert.equal((await db.query('select user_id from orders order by id desc limit 1')).rows[0].user_id,uid(11));
      await db.exec("select set_config('test.role','authenticated',false)");
    });
    await t.test('휴대폰 가입은 이메일 확인 없이 약관 완료 시 두 쿠폰 동시 지급·링크 만료', async () => {
      await add(20); await otp(20,'01055555555');
      const invitation=await rpc('public.get_my_signup_referral()');
      await as(null);
      await db.query("insert into auth.users(id,raw_app_meta_data) values($1,'{\"provider\":\"phone\"}')",[uid(21)]);
      await db.query("update auth.users set phone='821066666666',phone_confirmed_at=now() where id=$1",[uid(21)]);
      await as(21);
      assert.equal((await db.query('select terms_agreed_at,email_verified_at from member_profiles where user_id=$1',[uid(21)])).rows[0].terms_agreed_at,null);
      await rpc('public.attach_signup_referral($1)',[invitation.code]);
      assert.equal((await rpc('public.complete_signup_referral()')).status,'pending');
      await rpc("public.complete_oauth_signup(false,'회원','01066666666')");
      assert.equal((await rpc('public.complete_signup_referral()')).status,'rewarded');
      const rewards=(await db.query("select mc.issued_at from member_coupons mc join coupons c on c.id=mc.coupon_id where c.campaign_key in ('signup_referral_friend','signup_referral_inviter') and mc.user_id=any($1::uuid[])",[[uid(20),uid(21)]])).rows;
      assert.equal(rewards.length,2); assert.equal(rewards[0].issued_at.getTime(),rewards[1].issued_at.getTime());
      assert.equal((await rpc('public.get_signup_referral_offer($1)',[invitation.code])).code_expired,true);
      await as(20); assert.equal((await rpc('public.get_my_signup_referral()')).can_invite,false);
      await as(21); assert.equal((await rpc('public.get_my_signup_referral()')).can_invite,true);
    });
    await t.test('통합 후 중복 쿠폰의 환불 복원은 대표 계정에 한 장만 돌아간다',async()=>{
      await as(null);
      const source=(await db.query("select * from member_coupons where user_id=$1 and status='used'",[uid(10)])).rows[0];
      await db.query("update member_coupons set used_at=null,status='available',used_order_id=null where id=$1",[source.id]);
      assert.equal((await db.query('select status from member_coupons where id=$1',[source.id])).rows[0].status,'expired');
      assert.equal((await db.query('select status from member_coupons where user_id=$1 and coupon_id=$2',[uid(11),source.coupon_id])).rows[0].status,'available');
      assert.ok((await db.query('select withdrawal_scheduled_at from member_profiles where user_id=$1',[uid(10)])).rows[0].withdrawal_scheduled_at);
    });
    await t.test('개인정보 파기 시 번호 원문과 통합 스냅샷 제거, 혜택 HMAC 보존',async()=>{
      await as(null);
      const claims=Number((await db.query('select count(*) from member_signup_benefit_claims')).rows[0].count);
      await db.query('update member_profiles set personal_data_erased_at=now() where user_id=any($1::uuid[])',[[uid(11),uid(20)]]);
      assert.equal(Number((await db.query('select count(*) from member_phone_identities where user_id=any($1::uuid[])',[[uid(10),uid(11),uid(20)]])).rows[0].count),0);
      assert.equal(Number((await db.query('select count(*) from member_merge_row_audit')).rows[0].count),0);
      assert.equal(Number((await db.query('select count(*) from member_signup_benefit_claims')).rows[0].count),claims);
      const fingerprint=(await db.query('select phone_fingerprint from member_signup_benefit_claims limit 1')).rows[0].phone_fingerprint;
      assert.match(fingerprint,/^[a-f0-9]{64}$/);
    });
  } finally { await db.close(); }
});
