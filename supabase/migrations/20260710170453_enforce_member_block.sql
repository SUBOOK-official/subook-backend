-- 회원 차단 실효화 (2026-07-10)
--
-- 문제: admin_block_member는 member_profiles 플래그 + audit 이력만 기록하고,
--   (1) Supabase Auth 로그인/토큰 리프레시는 그대로 통과 (비번·카카오·구글 전부)
--   (2) 최신 get_current_auth_account_role(20260709191541)이 is_blocked를 안 봐서
--       프론트로 차단 신호가 전달되지 않음 (dual-role 재정의 때 회귀)
--   (3) add_to_cart는 2026051802 재정의 때 차단 가드가 누락(회귀),
--       confirm_member_purchase와 찜(wishlist RLS)은 애초에 가드 없음
-- → 차단해도 로그인·활동이 전부 가능했음 (운영자 실측 보고와 일치).
--
-- 조치 (4겹):
--   A. 차단/해제 RPC가 auth.users.banned_until도 세팅 → GoTrue가 로그인·리프레시 거부(user_banned)
--   B. 역할 RPC에 'blocked' 분기 → 아직 살아있는 액세스 토큰(~1h) 창구를 프론트 게이트로 차단
--   C. 쓰기 가드 복구: add_to_cart, confirm_member_purchase, wishlist insert RLS
--   D. 기존 차단 회원 백필 (is_blocked=true → banned_until 세팅)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- A-1) admin_block_member: auth 레벨 밴 추가 (20260525040333 정의 + 밴 1줄)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_block_member(
  p_user_id uuid,
  p_reason text default null,
  p_notify_user boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_email text;
  v_admin_user_id uuid;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_admin_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_admin_user_id := auth.uid();

  update public.member_profiles
  set
    is_blocked = true,
    blocked_at = now(),
    block_reason = nullif(btrim(p_reason), ''),
    updated_at = now()
  where user_id = p_user_id;

  if not found then
    raise exception '해당 회원을 찾을 수 없습니다.';
  end if;

  -- 진짜 로그인 차단: Supabase Auth 레벨 밴.
  -- 로그인 시도와 리프레시 토큰이 GoTrue에서 거부된다 (error code: user_banned).
  update auth.users
  set banned_until = now() + interval '100 years'
  where id = p_user_id;

  insert into public.member_block_history(
    target_user_id, admin_user_id, admin_email, action, reason, notify_user
  ) values (
    p_user_id, v_admin_user_id, v_admin_email, 'block', nullif(btrim(p_reason), ''), coalesce(p_notify_user, false)
  );

  return jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'is_blocked', true,
    'audit_logged', true
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A-2) admin_unblock_member: 밴 해제 추가
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_unblock_member(
  p_user_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_email text;
  v_admin_user_id uuid;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_admin_email := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_admin_user_id := auth.uid();

  update public.member_profiles
  set
    is_blocked = false,
    blocked_at = null,
    block_reason = null,
    updated_at = now()
  where user_id = p_user_id;

  if not found then
    raise exception '해당 회원을 찾을 수 없습니다.';
  end if;

  update auth.users
  set banned_until = null
  where id = p_user_id;

  insert into public.member_block_history(
    target_user_id, admin_user_id, admin_email, action, reason, notify_user
  ) values (
    p_user_id, v_admin_user_id, v_admin_email, 'unblock', nullif(btrim(p_reason), ''), false
  );

  return jsonb_build_object(
    'success', true,
    'user_id', p_user_id,
    'is_blocked', false,
    'audit_logged', true
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B) get_current_auth_account_role: 'blocked' 분기 복구
--    (20260709191541 정의와 동일 시그니처 — CREATE OR REPLACE로 충분, drop 불필요.
--     차단은 관리자 여부보다 우선. admin-web 접근은 is_admin_user() 기반이라 무영향)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_current_auth_account_role()
returns table (
  account_role text,
  user_id uuid,
  email text,
  name text,
  nickname text,
  phone text,
  marketing_opt_in boolean,
  email_verified_at timestamptz,
  terms_agreed_at timestamptz,
  privacy_agreed_at timestamptz,
  withdrawal_requested_at timestamptz,
  withdrawal_scheduled_at timestamptz,
  personal_data_erased_at timestamptz,
  is_admin boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with viewer as (
    select
      auth.uid() as user_id,
      lower(coalesce(auth.jwt() ->> 'email', '')) as email
  )
  select
    case
      when viewer.user_id is null then 'guest'
      when mp.personal_data_erased_at is not null then 'withdrawn'
      when mp.withdrawal_requested_at is not null then 'withdrawal_pending'
      when mp.is_blocked then 'blocked'
      when mp.user_id is not null then 'member'
      when exists (
        select 1
        from public.admin_users au
        where lower(au.email) = viewer.email
      ) then 'admin'
      else 'unknown'
    end as account_role,
    viewer.user_id,
    coalesce(mp.email, viewer.email) as email,
    mp.name,
    mp.nickname,
    mp.phone,
    coalesce(mp.marketing_opt_in, false) as marketing_opt_in,
    mp.email_verified_at,
    mp.terms_agreed_at,
    mp.privacy_agreed_at,
    mp.withdrawal_requested_at,
    mp.withdrawal_scheduled_at,
    mp.personal_data_erased_at,
    exists (
      select 1
      from public.admin_users au
      where lower(au.email) = viewer.email
    ) as is_admin
  from viewer
  left join public.member_profiles mp
    on mp.user_id = viewer.user_id;
$$;

grant execute on function public.get_current_auth_account_role() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- C-1) add_to_cart: 차단 가드 복구 (2026051802 정의 + assert 1줄.
--      2026051505에 있던 가드가 2026051802 재정의 때 누락된 회귀)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.add_to_cart(
  p_book_id bigint,
  p_product_id bigint default null,
  p_quantity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_cart_id bigint;
  v_cart_count integer;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  -- 단일재고 모델: quantity는 항상 1
  -- cart 개수 상한 (DoS 방어): 100개 초과 시 거부
  select count(*) into v_cart_count
    from public.cart_items
   where user_id = v_user_id;

  if v_cart_count >= 100
     and not exists (
       select 1 from public.cart_items
        where user_id = v_user_id and book_id = p_book_id
     )
  then
    raise exception '장바구니에 담을 수 있는 최대 개수(100)를 초과했습니다.';
  end if;

  insert into public.cart_items (user_id, book_id, product_id, quantity)
  values (v_user_id, p_book_id, p_product_id, 1)
  on conflict (user_id, book_id) do update
    set quantity = 1,
        updated_at = now()
  returning id into v_cart_id;

  return jsonb_build_object('cart_item_id', v_cart_id);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C-2) confirm_member_purchase: 차단 가드 추가 (20260602030000 정의 + assert 1줄)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.confirm_member_purchase(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_order record;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  select * into v_order from public.orders where id = p_order_id and user_id = v_user_id;
  if not found then
    raise exception '주문을 찾을 수 없습니다.';
  end if;

  if v_order.status != 'delivered' then
    raise exception '배송완료 상태에서만 구매확정이 가능합니다. (현재: %)', v_order.status;
  end if;

  if v_order.confirmed_at is not null then
    raise exception '이미 구매확정된 주문입니다.';
  end if;

  update public.orders
  set
    status = 'confirmed',
    confirmed_at = now(),
    updated_at = now()
  where id = p_order_id and user_id = v_user_id;

  return jsonb_build_object('success', true, 'order_id', p_order_id);
end;
$$;

grant execute on function public.confirm_member_purchase(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- C-3) 찜: insert RLS에 차단 검사 추가 (RPC 없이 직접 insert하는 유일한 회원 쓰기 경로)
-- ─────────────────────────────────────────────────────────────────────────────
drop policy if exists wishlist_items_insert_self on public.wishlist_items;

create policy wishlist_items_insert_self
  on public.wishlist_items
  for insert
  to authenticated
  with check (
    auth.uid() = user_id
    and not exists (
      select 1
      from public.member_profiles mp
      where mp.user_id = auth.uid()
        and mp.is_blocked
    )
  );

-- ─────────────────────────────────────────────────────────────────────────────
-- D) 기존 차단 회원 백필: 이미 is_blocked=true인 계정에 auth 밴 소급 적용
-- ─────────────────────────────────────────────────────────────────────────────
update auth.users u
set banned_until = now() + interval '100 years'
from public.member_profiles mp
where mp.user_id = u.id
  and mp.is_blocked
  and (u.banned_until is null or u.banned_until <= now());

commit;
