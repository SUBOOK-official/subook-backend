-- 회원이 각 계정에 다시 로그인하여 소유를 증명하고 대표 계정을 직접 선택한다.
-- 같은 raw phone만으로 다른 계정의 주문/자산을 옮기지 않는다.
-- 통합은 단일 트랜잭션. 변경 전 행은 deny-all 감사 테이블에 보존한다.
begin;
alter table public.member_merge_requests add column created_at timestamptz not null default now();
alter table public.member_merge_requests add column candidate_users uuid[] not null default '{}';
create table public.member_merge_row_audit (
  request_id uuid not null references public.member_merge_requests(id),
  table_name text not null,
  old_row jsonb not null,
  recorded_at timestamptz not null default now()
);
alter table public.member_merge_row_audit enable row level security;
revoke all on public.member_merge_row_audit from public,anon,authenticated;

create function public._member_merge_view(p_request public.member_merge_requests) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',p_request.id,'expires_at',p_request.expires_at,'completed',p_request.completed_at is not null,
    'target_user_id',p_request.target_user_id,'accounts',coalesce(jsonb_agg(jsonb_build_object(
      'id',m.user_id,'email',case when m.user_id=any(p_request.verified_users) then
        case when m.email like '%@oauth.subook.local' then '휴대폰 계정' else m.email end
        else left(split_part(m.email,'@',1),2)||'***@'||split_part(m.email,'@',2) end,
      'provider',u.raw_app_meta_data->>'provider','verified',m.user_id=any(p_request.verified_users),
      'orders',case when m.user_id=any(p_request.verified_users) then (select count(*) from public.orders where user_id=m.user_id) end,
      'points',case when m.user_id=any(p_request.verified_users) then (select coalesce(sum(remaining),0) from public.point_lots where user_id=m.user_id and voided_at is null and expires_at>now()) end
    ) order by u.created_at),'[]'))
  from public.member_profiles m join auth.users u on u.id=m.user_id where m.user_id=any(p_request.candidate_users);
$$;

create function public.start_member_account_merge() returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_proof public.member_phone_proofs%rowtype; v_request public.member_merge_requests%rowtype;
  v_secret text:=encode(extensions.gen_random_bytes(32),'hex'); v_candidates uuid[];
begin
  if auth.uid() is null or not (select merge_enabled from public.member_identity_policy where singleton) then raise exception '계정 통합을 준비 중입니다.'; end if;
  select * into v_proof from public.member_phone_proofs where user_id=auth.uid() and expires_at>now();
  if not found then raise exception '휴대폰을 다시 인증해 주세요.'; end if;
  if exists(select 1 from public.member_account_merges where source_user_id=auth.uid()) then raise exception '대표 계정으로 로그인해 주세요.'; end if;
  select array_agg(m.user_id order by m.user_id) into v_candidates from public.member_profiles m
  where (m.user_id=auth.uid() or exists(select 1 from public.member_legacy_phone_accounts l where l.user_id=m.user_id and l.phone=v_proof.phone)
      or exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone=v_proof.phone))
    and not exists(select 1 from public.member_phone_identities i where i.user_id=m.user_id and i.phone<>v_proof.phone)
    and not coalesce(m.is_blocked,false) and m.withdrawal_requested_at is null and m.personal_data_erased_at is null
    and not exists(select 1 from public.admin_users a where lower(a.email)=lower(m.email))
    and not exists(select 1 from public.member_account_merges x where x.source_user_id=m.user_id);
  if not coalesce(auth.uid()=any(v_candidates),false) then raise exception '통합할 수 없는 계정입니다.'; end if;
  insert into public.member_merge_requests(requester_id,phone,secret_hash,verified_users,candidate_users,expires_at)
    values(auth.uid(),v_proof.phone,encode(extensions.digest(v_secret,'sha256'),'hex'),array[auth.uid()],v_candidates,v_proof.expires_at)
    returning * into v_request;
  return public._member_merge_view(v_request)||jsonb_build_object('secret',v_secret);
end;
$$;

create function public._get_member_merge_request(p_id uuid,p_secret text) returns public.member_merge_requests
language plpgsql stable security definer set search_path='' as $$
declare r public.member_merge_requests%rowtype;
begin
  select * into r from public.member_merge_requests where id=p_id
    and secret_hash=encode(extensions.digest(coalesce(p_secret,''),'sha256'),'hex');
  if not found or auth.uid() is null or not auth.uid()=any(r.candidate_users) then raise exception '계정 통합 요청을 확인할 수 없습니다.'; end if;
  if r.completed_at is null and r.expires_at<=now() then raise exception '인증 시간이 만료되었습니다. 휴대폰 인증부터 다시 진행해 주세요.'; end if;
  return r;
end;
$$;
create function public.get_member_account_merge(p_id uuid,p_secret text) returns jsonb
language sql stable security definer set search_path='' as $$
  select public._member_merge_view(public._get_member_merge_request(p_id,p_secret));
$$;
create function public.prove_member_account_merge(p_id uuid,p_secret text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.member_merge_requests%rowtype;
begin
  perform 1 from public.member_merge_requests where id=p_id for update;
  r:=public._get_member_merge_request(p_id,p_secret);
  if r.completed_at is not null then return public._member_merge_view(r); end if;
  if not auth.uid()=any(r.verified_users) then
    -- 사용자 전체 last_sign_in_at 대신 이번 요청의 서명된 인증 증거를 확인한다.
    -- 다른 기기의 로그인이나 token_refresh만으로 오래된 세션이 통합 증명이 되지 않는다.
    if not exists(select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) a
      where a->>'method' in ('password','oauth','otp','magiclink','recovery')
        and case when a->>'timestamp' ~ '^[0-9]+$' then (a->>'timestamp')::numeric
          >= floor(extract(epoch from r.created_at)) else false end) then
      raise exception '이 계정에 다시 로그인하여 소유를 확인해 주세요.';
    end if;
    update public.member_merge_requests set verified_users=array_append(verified_users,auth.uid()) where id=p_id returning * into r;
  end if;
  return public._member_merge_view(r);
end;
$$;

create function public.complete_member_account_merge(p_id uuid,p_secret text,p_target uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.member_merge_requests%rowtype; v_source uuid; v_sources uuid[]; t text; col text;
  v_owner uuid; v_target public.member_profiles%rowtype;
begin
  if not (select merge_enabled from public.member_identity_policy where singleton) then raise exception '계정 통합을 준비 중입니다.'; end if;
  perform 1 from public.member_merge_requests where id=p_id for update;
  r:=public._get_member_merge_request(p_id,p_secret);
  if p_target<>auth.uid() or not p_target=any(r.verified_users) then raise exception '선택한 대표 계정으로 로그인해 주세요.'; end if;
  if r.completed_at is not null then
    if r.target_user_id<>p_target then raise exception '이미 다른 계정으로 통합된 요청입니다.'; end if;
    return jsonb_build_object('success',true,'phone',r.phone,'target_user_id',p_target);
  end if;
  if cardinality(r.verified_users)<2 then raise exception '통합할 기존 계정의 로그인을 먼저 확인해 주세요.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('member-phone:'||r.phone,0));
  perform 1 from public.member_profiles where user_id=any(r.verified_users) order by user_id for update;
  if exists(select 1 from public.member_profiles m where m.user_id=any(r.verified_users) and
    (coalesce(m.is_blocked,false) or m.withdrawal_requested_at is not null or m.personal_data_erased_at is not null
      or exists(select 1 from public.admin_users a where lower(a.email)=lower(m.email))))
    or exists(select 1 from public.member_account_merges where source_user_id=any(r.verified_users)) then
    raise exception '이용 제한 또는 이미 통합된 계정이 포함되어 있습니다. 고객센터로 문의해 주세요.';
  end if;
  select user_id into v_owner from public.member_phone_identities where phone=r.phone;
  if v_owner is not null and not v_owner=any(r.verified_users) then raise exception '이 번호의 기존 계정도 로그인 확인이 필요합니다.'; end if;
  if exists(select 1 from public.member_phone_identities where user_id=any(r.verified_users) and phone<>r.phone) then
    raise exception '다른 인증 번호의 계정은 통합할 수 없습니다.';
  end if;
  select * into v_target from public.member_profiles where user_id=p_target;
  select array_agg(x) into v_sources from unnest(r.verified_users) x where x<>p_target;

  -- 승인 콜백/포인트 사용/정산 처리와 이관이 엇갈리지 않도록 짧게 직렬화한다.
  lock table public.orders,public.pg_checkout_sessions,public.member_coupons,public.point_lots,public.point_transactions,
    public.settlements,public.shipments,public.pickup_requests in share row exclusive mode;
  if exists(select 1 from public.pg_checkout_sessions where user_id=any(r.verified_users) and status='created' and created_at>now()-interval '24 hours')
    or exists(select 1 from public.orders where user_id=any(r.verified_users) and payment_status='pending') then
    raise exception '진행 중인 결제로 통합을 보류했어요. 입금 대기 주문은 입금을 완료하거나 고객센터에 취소를 요청해 주세요. 결제창만 열었다가 닫은 경우에는 최대 24시간 후 통합할 수 있습니다.';
  end if;

  foreach t in array array['orders','pg_checkout_sessions','shipments','pickup_requests','settlements','point_lots','point_transactions',
    'reviews','legacy_reviews','member_notifications','member_shipping_addresses','member_settlement_accounts','member_coupons',
    'cart_items','wishlist_items','restock_keyword_subscriptions','restock_notifications','event_subscriptions','retention_experiment_members',
    'member_notes','notification_logs','legacy_sixshop_customers'] loop
    col:=case t when 'settlements' then 'seller_user_id' when 'member_notes' then 'member_user_id'
      when 'notification_logs' then 'recipient_user_id' when 'legacy_sixshop_customers' then 'backfilled_user_id' else 'user_id' end;
    execute format('insert into public.member_merge_row_audit(request_id,table_name,old_row) select $1,$2,to_jsonb(x) from public.%I x where %I=any($3)',t,col)
      using p_id,t,r.verified_users;
  end loop;
  insert into public.member_merge_row_audit(request_id,table_name,old_row)
    select p_id,'member_profiles',to_jsonb(m) from public.member_profiles m where user_id=any(r.verified_users);

  foreach v_source in array v_sources loop
    -- 배송지/정산계좌 내용은 유지하고 대표 계정의 기본값을 우선한다.
    if exists(select 1 from public.member_shipping_addresses where user_id=p_target and is_default) then
      update public.member_shipping_addresses set is_default=false where user_id=v_source;
    end if;
    if exists(select 1 from public.member_settlement_accounts where user_id=p_target and is_default) then
      update public.member_settlement_accounts set is_default=false where user_id=v_source;
    end if;
    -- 같은 상품/알림의 중복 행만 제거. 원문은 감사 테이블에 보존된다.
    delete from public.cart_items s using public.cart_items d where s.user_id=v_source and d.user_id=p_target and s.book_id=d.book_id;
    delete from public.wishlist_items s using public.wishlist_items d where s.user_id=v_source and d.user_id=p_target and s.product_id=d.product_id;
    delete from public.restock_keyword_subscriptions s using public.restock_keyword_subscriptions d where s.user_id=v_source and d.user_id=p_target and s.keyword_norm=d.keyword_norm;
    delete from public.restock_notifications s using public.restock_notifications d where s.user_id=v_source and d.user_id=p_target and s.product_id=d.product_id and s.notified_at is null and d.notified_at is null;
    delete from public.retention_experiment_members s using public.retention_experiment_members d where s.user_id=v_source and d.user_id=p_target and s.experiment_id=d.experiment_id;
    -- 동일 쿠폰의 사용 이력은 지우지 않는다. 이미 사용된 혜택은 추가 사용 불가.
    update public.member_coupons d set status='expired' where d.user_id=p_target and d.status='available'
      and exists(select 1 from public.member_coupons s where s.user_id=v_source and s.coupon_id=d.coupon_id and s.used_at is not null);
    update public.member_coupons s set status='expired' where s.user_id=v_source and s.status='available'
      and exists(select 1 from public.member_coupons d where d.user_id=p_target and d.coupon_id=s.coupon_id);
    update public.member_coupons s set user_id=p_target where s.user_id=v_source
      and not exists(select 1 from public.member_coupons d where d.user_id=p_target and d.coupon_id=s.coupon_id);
    foreach t in array array['orders','pg_checkout_sessions','shipments','pickup_requests','settlements','point_lots','point_transactions',
      'reviews','legacy_reviews','member_notifications','member_shipping_addresses','member_settlement_accounts','cart_items','wishlist_items',
      'restock_keyword_subscriptions','restock_notifications','event_subscriptions','retention_experiment_members','member_notes','notification_logs','legacy_sixshop_customers'] loop
      col:=case t when 'settlements' then 'seller_user_id' when 'member_notes' then 'member_user_id'
        when 'notification_logs' then 'recipient_user_id' when 'legacy_sixshop_customers' then 'backfilled_user_id' else 'user_id' end;
      execute format('update public.%I set %I=$1 where %I=$2',t,col,col) using p_target,v_source;
    end loop;
    insert into public.member_account_merges(source_user_id,target_user_id,details)
      values(v_source,p_target,jsonb_build_object('request_id',p_id,'phone',r.phone));
    update public.member_account_merges set target_user_id=p_target where target_user_id=v_source;
    -- 통합된 원 계정은 기존 30일 개인정보 파기 절차로 정리한다. 자산은 이미 대표 계정에 귀속됨.
    update public.member_profiles set withdrawal_requested_at=now(),withdrawal_scheduled_at=now()+interval '30 days'
      where user_id=v_source;
  end loop;
  insert into public.member_phone_identities(phone,user_id) values(r.phone,p_target)
    on conflict(phone) do update set user_id=excluded.user_id,verified_at=now();
  update public.member_profiles set phone=r.phone,verified_phone=r.phone,phone_verified_at=now(),updated_at=now() where user_id=p_target;
  update public.member_merge_requests set completed_at=now(),target_user_id=p_target where id=p_id;
  return jsonb_build_object('success',true,'phone',r.phone,'target_user_id',p_target);
end;
$$;

-- 통합 뒤 지연 도착한 서버 콜백은 대표 계정에 귀속; 옛 회원 토큰의 쓰기는 차단.
create function public.guard_merged_member_owner() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_old_owner uuid:=(to_jsonb(new)->>tg_argv[0])::uuid; v_target uuid;
begin
  if auth.role()='authenticated' and exists(select 1 from public.member_account_merges where source_user_id=auth.uid()) then
    raise exception '대표 계정으로 다시 로그인해 주세요.';
  end if;
  select target_user_id into v_target from public.member_account_merges where source_user_id=v_old_owner;
  if v_target is not null then new:=jsonb_populate_record(new,jsonb_build_object(tg_argv[0],v_target)); end if;
  return new;
end;
$$;
do $$ declare t text; col text; begin
  foreach t in array array['orders','pg_checkout_sessions','shipments','pickup_requests','settlements','point_lots','point_transactions'] loop
    col:=case t when 'settlements' then 'seller_user_id' else 'user_id' end;
    execute format('create trigger guard_merged_member_owner before insert or update on public.%I for each row execute function public.guard_merged_member_owner(%L)',t,col);
  end loop;
end $$;
revoke all on function public._member_merge_view(public.member_merge_requests),public._get_member_merge_request(uuid,text),public.guard_merged_member_owner() from public,anon,authenticated;
revoke all on function public.start_member_account_merge(),public.get_member_account_merge(uuid,text),public.prove_member_account_merge(uuid,text),public.complete_member_account_merge(uuid,text,uuid) from public,anon;
grant execute on function public.start_member_account_merge(),public.get_member_account_merge(uuid,text),public.prove_member_account_merge(uuid,text),public.complete_member_account_merge(uuid,text,uuid) to authenticated;
select pg_notify('pgrst','reload schema');
-- 전화 Auth 연결의 재시도용 조회. 타 계정의 번호는 반환하지 않는다.
create function public.get_member_phone_binding(p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare v_phone text; v_auth_owner uuid;
begin
  if not exists(select 1 from public.member_profiles where user_id=p_user_id
    and not coalesce(is_blocked,false) and withdrawal_requested_at is null and personal_data_erased_at is null) then
    raise exception '이용할 수 없는 계정입니다.';
  end if;
  select phone into v_phone from public.member_phone_identities where user_id=p_user_id;
  if v_phone is null or exists(select 1 from public.member_account_merges where source_user_id=p_user_id) then raise exception '휴대폰 인증이 필요합니다.'; end if;
  select id into v_auth_owner from auth.users where public.normalize_member_phone(phone)=v_phone;
  if v_auth_owner is not null and v_auth_owner<>p_user_id and not exists(
    select 1 from public.member_account_merges where source_user_id=v_auth_owner and target_user_id=p_user_id) then
    raise exception '기존 휴대폰 계정과 통합을 먼저 완료해 주세요.';
  end if;
  return jsonb_build_object('phone','82'||substr(v_phone,2),'previous_user_id',case when v_auth_owner<>p_user_id then v_auth_owner end);
end;
$$;
revoke all on function public.get_member_phone_binding(uuid) from public,anon,authenticated;
grant execute on function public.get_member_phone_binding(uuid) to service_role;

-- 사용 이력 보존 때문에 원 계정에 남긴 중복 쿠폰의 환불 복원도 대표 계정으로 전달한다.
create function public.restore_merged_member_coupon() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_target uuid; v_existing public.member_coupons%rowtype;
begin
  if new.status<>'available' or old.used_at is null or new.used_at is not null then return new; end if;
  select target_user_id into v_target from public.member_account_merges where source_user_id=new.user_id;
  if v_target is null then return new; end if;
  select * into v_existing from public.member_coupons where user_id=v_target and coupon_id=new.coupon_id for update;
  if not found then new.user_id:=v_target; return new; end if;
  if v_existing.used_at is null then
    update public.member_coupons set status=case when new.expires_at<=now() then 'expired' else 'available' end,
      expires_at=new.expires_at where id=v_existing.id;
  end if;
  new.status:='expired';
  return new;
end;
$$;
create trigger restore_merged_member_coupon before update of used_at,status on public.member_coupons
  for each row execute function public.restore_merged_member_coupon();
revoke all on function public.restore_merged_member_coupon() from public,anon,authenticated;

-- 기존 탈퇴 개인정보 파기와 함께 번호 원문/통합 스냅샷도 제거한다.
-- 혜택 중복 방지 원장에는 역산할 수 없는 서버 HMAC만 보존한다.
create function public.erase_member_phone_identity() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_users uuid[]; v_phones text[];
begin
  if new.personal_data_erased_at is null or old.personal_data_erased_at is not null then return new; end if;
  select array_agg(x) into v_users from (select new.user_id x union select source_user_id from public.member_account_merges where target_user_id=new.user_id) s;
  select array_agg(phone) into v_phones from public.member_phone_identities where user_id=any(v_users);
  delete from public.member_merge_row_audit where request_id in(select id from public.member_merge_requests where candidate_users && v_users);
  update public.member_merge_requests set phone='',secret_hash='' where candidate_users && v_users;
  update public.member_account_merges set details=details-'phone' where source_user_id=any(v_users) or target_user_id=new.user_id;
  delete from public.member_phone_identities where user_id=any(v_users);
  delete from public.member_phone_proofs where user_id=any(v_users);
  delete from public.member_legacy_phone_accounts where user_id=any(v_users);
  delete from public.phone_verification_codes where user_id=any(v_users);
  delete from public.member_auth_sms_attempts where phone=any(v_phones);
  new.verified_phone:=null; new.phone_verified_at:=null;
  return new;
end;
$$;
create trigger erase_member_phone_identity before update of personal_data_erased_at on public.member_profiles
  for each row execute function public.erase_member_phone_identity();
revoke all on function public.erase_member_phone_identity() from public,anon,authenticated;
commit;
