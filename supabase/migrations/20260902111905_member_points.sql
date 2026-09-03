-- 회원 포인트 제도 (2026-09-02 사용자 결정)
--
-- 1P = 1원. 적립 = 후기 작성(글 500P / 사진 1,000P). 사용 = 주문 시 차감.
-- 사용 규칙: 1,000P 이상 보유 시 · 상품금액 15,000원 이상 주문 · 상품금액의 20%까지.
-- 유효기간 = 적립일 + 12개월(lot 단위, 만료 lot은 잔액 계산에서 제외 — 별도 크론 없음).
-- 회수 = 후기 숨김 / 그 주문 전액 환불 시 해당 적립 lot 무효화(이미 쓴 만큼은 추심하지 않음).
-- 복구 = 포인트를 쓴 주문이 취소/환불되면 사용분 원복(만료된 lot이면 30일 유예 부여).
--
-- 재무 근거(2026-09-02 계산): 셀러 정산은 판매가 기준이라 포인트는 전액 수북 수수료(≈41%)
-- 부담. 20% 상한이면 어떤 주문도 최소 21%p 마진이 남는다. 상한·환불 회수 두 가지가 손해 방어선.
--
-- 구조:
--   point_lots        적립 단위(잔여 remaining, 만료, 무효화)
--   point_usages      주문별 lot 소진 기록(취소 시 원복용)
--   point_transactions 회원 노출용 원장(+적립 / -사용·회수·만료)
--   orders.points_used 주문에 쓴 포인트(총액에서 이미 차감됨)
--
-- ⚠ create_order_core 시그니처가 바뀐다(p_points_amount 추가). 옛 시그니처는 drop —
--   두 오버로드가 공존하면 positional 호출이 모호해진다. 래퍼 RPC(create_order,
--   create_pg_checkout_session, finalize_pg_checkout_session)는 여기서 재정의.
--   게스트 RPC 2종은 이름 인자 호출이라 재정의 불필요(포인트 기본값 0).

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) 정책 상수 — 프런트 publicPoints.js POINT_POLICY와 같은 값 유지
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.point_policy()
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'earn_text', 500,
    'earn_photo', 1000,
    'min_balance_to_use', 1000,
    'min_order_subtotal', 15000,
    'max_use_ratio', 0.2,
    'expiry_months', 12
  );
$$;

grant execute on function public.point_policy() to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.point_lots (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null check (amount > 0),
  remaining integer not null check (remaining >= 0),
  source text not null check (source in ('review', 'admin')),
  review_id bigint references public.reviews(id) on delete set null,
  order_id bigint references public.orders(id) on delete set null,
  note text,
  expires_at timestamptz not null,
  voided_at timestamptz,
  void_reason text,
  created_at timestamptz not null default now()
);
comment on table public.point_lots is '포인트 적립 단위 — remaining이 잔여, expires_at 지나면 잔액 제외, voided_at이면 회수됨 (2026-09-02)';

create index if not exists idx_point_lots_user_active
  on public.point_lots (user_id, expires_at, id)
  where voided_at is null and remaining > 0;
create index if not exists idx_point_lots_review on public.point_lots (review_id) where review_id is not null;
create index if not exists idx_point_lots_order on public.point_lots (order_id) where order_id is not null;

create table if not exists public.point_usages (
  id bigint generated always as identity primary key,
  lot_id bigint not null references public.point_lots(id) on delete cascade,
  order_id bigint not null references public.orders(id) on delete cascade,
  amount integer not null check (amount > 0),
  restored_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_point_usages_order on public.point_usages (order_id);

create table if not exists public.point_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null,
  kind text not null check (kind in ('review_earn', 'order_use', 'order_restore', 'reclaim', 'admin_adjust')),
  lot_id bigint references public.point_lots(id) on delete set null,
  order_id bigint references public.orders(id) on delete set null,
  review_id bigint references public.reviews(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists idx_point_transactions_user_created
  on public.point_transactions (user_id, created_at desc, id desc);

alter table public.point_lots enable row level security;
alter table public.point_usages enable row level security;
alter table public.point_transactions enable row level security;

drop policy if exists "point_lots_select_own" on public.point_lots;
create policy "point_lots_select_own" on public.point_lots
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "point_lots_admin_all" on public.point_lots;
create policy "point_lots_admin_all" on public.point_lots
  for all to authenticated using (public.is_admin_user()) with check (public.is_admin_user());

drop policy if exists "point_usages_admin_all" on public.point_usages;
create policy "point_usages_admin_all" on public.point_usages
  for all to authenticated using (public.is_admin_user()) with check (public.is_admin_user());

drop policy if exists "point_transactions_select_own" on public.point_transactions;
create policy "point_transactions_select_own" on public.point_transactions
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "point_transactions_admin_all" on public.point_transactions;
create policy "point_transactions_admin_all" on public.point_transactions
  for all to authenticated using (public.is_admin_user()) with check (public.is_admin_user());

alter table public.orders add column if not exists points_used integer not null default 0;
comment on column public.orders.points_used is '주문에 사용한 포인트(원). total_amount에는 이미 차감 반영됨 (2026-09-02)';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) 잔액·적립·소진·원복·회수 내부 함수 (클라이언트 직접 호출 금지)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_point_balance(p_user_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(remaining), 0)::integer
  from public.point_lots
  where user_id = p_user_id
    and voided_at is null
    and expires_at > now()
    and remaining > 0;
$$;

revoke all on function public.get_point_balance(uuid) from public;
revoke all on function public.get_point_balance(uuid) from anon;
revoke all on function public.get_point_balance(uuid) from authenticated;

-- 적립 lot 생성 + 원장 기록
create or replace function public.grant_points(
  p_user_id uuid,
  p_amount integer,
  p_source text,
  p_kind text,
  p_review_id bigint default null,
  p_order_id bigint default null,
  p_note text default null,
  p_expires_at timestamptz default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot_id bigint;
  v_expires timestamptz := coalesce(
    p_expires_at,
    now() + make_interval(months => (public.point_policy()->>'expiry_months')::integer)
  );
begin
  if p_user_id is null or coalesce(p_amount, 0) <= 0 then
    raise exception 'grant_points: invalid args';
  end if;

  insert into public.point_lots (user_id, amount, remaining, source, review_id, order_id, note, expires_at)
  values (p_user_id, p_amount, p_amount, p_source, p_review_id, p_order_id, p_note, v_expires)
  returning id into v_lot_id;

  insert into public.point_transactions (user_id, amount, kind, lot_id, order_id, review_id, note)
  values (p_user_id, p_amount, p_kind, v_lot_id, p_order_id, p_review_id, p_note);

  return v_lot_id;
end;
$$;

revoke all on function public.grant_points(uuid, integer, text, text, bigint, bigint, text, timestamptz) from public;
revoke all on function public.grant_points(uuid, integer, text, text, bigint, bigint, text, timestamptz) from anon;
revoke all on function public.grant_points(uuid, integer, text, text, bigint, bigint, text, timestamptz) from authenticated;

-- 주문에 포인트 소진 — 만료 임박 lot부터 FIFO. 잔액 부족이면 예외(호출자 트랜잭션 롤백).
create or replace function public.consume_points_for_order(
  p_user_id uuid,
  p_order_id bigint,
  p_amount integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_left integer := coalesce(p_amount, 0);
  v_lot record;
  v_take integer;
begin
  if v_left <= 0 then
    return;
  end if;

  for v_lot in
    select id, remaining
    from public.point_lots
    where user_id = p_user_id
      and voided_at is null
      and expires_at > now()
      and remaining > 0
    order by expires_at, id
    for update
  loop
    exit when v_left <= 0;
    v_take := least(v_lot.remaining, v_left);
    update public.point_lots set remaining = remaining - v_take where id = v_lot.id;
    insert into public.point_usages (lot_id, order_id, amount) values (v_lot.id, p_order_id, v_take);
    v_left := v_left - v_take;
  end loop;

  if v_left > 0 then
    raise exception '보유 포인트가 부족해요. (부족분 %P)', v_left;
  end if;

  insert into public.point_transactions (user_id, amount, kind, order_id, note)
  values (p_user_id, -p_amount, 'order_use', p_order_id, '주문 사용');
end;
$$;

revoke all on function public.consume_points_for_order(uuid, bigint, integer) from public;
revoke all on function public.consume_points_for_order(uuid, bigint, integer) from anon;
revoke all on function public.consume_points_for_order(uuid, bigint, integer) from authenticated;

-- 취소/환불된 주문의 사용 포인트 원복 — 만료된 lot이면 30일 유예를 준다.
create or replace function public.restore_points_for_order(p_order_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usage record;
  v_total integer := 0;
  v_user_id uuid;
begin
  for v_usage in
    select u.id, u.lot_id, u.amount, l.user_id, l.expires_at, l.voided_at
    from public.point_usages u
    join public.point_lots l on l.id = u.lot_id
    where u.order_id = p_order_id
      and u.restored_at is null
    for update of u
  loop
    update public.point_usages set restored_at = now() where id = v_usage.id;
    -- 회수(무효화)된 lot은 되살리지 않는다 — 후기 숨김·환불 회수가 취소 원복으로 뒤집히면 안 됨
    if v_usage.voided_at is not null then
      continue;
    end if;
    update public.point_lots
    set remaining = remaining + v_usage.amount,
        expires_at = greatest(expires_at, now() + interval '30 days')
    where id = v_usage.lot_id;
    v_total := v_total + v_usage.amount;
    v_user_id := v_usage.user_id;
  end loop;

  if v_total > 0 then
    insert into public.point_transactions (user_id, amount, kind, order_id, note)
    values (v_user_id, v_total, 'order_restore', p_order_id, '주문 취소·환불로 복구');
  end if;

  return v_total;
end;
$$;

revoke all on function public.restore_points_for_order(bigint) from public;
revoke all on function public.restore_points_for_order(bigint) from anon;
revoke all on function public.restore_points_for_order(bigint) from authenticated;

-- 후기 적립 회수 — 남은 잔여만 무효화(이미 쓴 만큼은 추심하지 않음). 멱등.
create or replace function public.reclaim_review_points(p_review_id bigint, p_reason text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lot record;
  v_total integer := 0;
begin
  for v_lot in
    select id, user_id, remaining
    from public.point_lots
    where review_id = p_review_id
      and voided_at is null
    for update
  loop
    update public.point_lots
    set remaining = 0,
        voided_at = now(),
        void_reason = p_reason
    where id = v_lot.id;
    if v_lot.remaining > 0 then
      insert into public.point_transactions (user_id, amount, kind, lot_id, review_id, note)
      values (v_lot.user_id, -v_lot.remaining, 'reclaim', v_lot.id, p_review_id, p_reason);
      v_total := v_total + v_lot.remaining;
    end if;
  end loop;
  return v_total;
end;
$$;

revoke all on function public.reclaim_review_points(bigint, text) from public;
revoke all on function public.reclaim_review_points(bigint, text) from anon;
revoke all on function public.reclaim_review_points(bigint, text) from authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) 주문 상태 트리거 — 취소/환불 시 사용 포인트 원복 + 전액환불 시 후기 적립 회수,
--    취소 복원(cancelled → pending) 시 재차감(잔액 부족이면 복원 거부)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sync_points_on_order_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review_id bigint;
begin
  if new.status in ('cancelled', 'refunded') and old.status not in ('cancelled', 'refunded') then
    if coalesce(new.points_used, 0) > 0 then
      perform public.restore_points_for_order(new.id);
    end if;
    if new.status = 'refunded' then
      select id into v_review_id from public.reviews where order_id = new.id limit 1;
      if v_review_id is not null then
        perform public.reclaim_review_points(v_review_id, '주문 전액 환불');
      end if;
    end if;
  elsif old.status = 'cancelled' and new.status = 'pending' and coalesce(new.points_used, 0) > 0
        and new.user_id is not null then
    -- admin_restore_cancelled_order: 원복됐던 포인트를 다시 차감. 부족하면 복원 자체를 막는다.
    perform public.consume_points_for_order(new.user_id, new.id, new.points_used);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_sync_points on public.orders;
create trigger trg_orders_sync_points
after update of status on public.orders
for each row execute function public.sync_points_on_order_status();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) create_order_core 재정의 — p_points_amount 추가 (옛 시그니처 drop)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean
);

create or replace function public.create_order_core(
  p_user_id uuid,
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'bank_transfer'::text,
  p_member_coupon_id bigint default null::bigint,
  p_refund_bank text default null,
  p_refund_account_number text default null,
  p_refund_account_holder text default null,
  p_order_number text default null,
  p_validate_only boolean default false,
  p_is_guest boolean default false,
  p_points_amount integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_blocked boolean;
  v_phone_digits text;
  v_order_id bigint;
  v_order_number text;
  v_subtotal integer := 0;
  v_shipping_fee integer := 3000;
  v_discount integer := 0;
  v_total_amount integer;
  v_item_count integer;
  v_idx integer;
  v_book record;
  v_product_cover text;
  v_member_coupon record;
  v_coupon record;
  v_used_count integer;
  v_free_shipping_threshold integer := 50000;
  v_active_count integer;
  v_is_free_shipping_coupon boolean := false;
  v_remote_surcharge integer := 0;
  v_points integer := greatest(coalesce(p_points_amount, 0), 0);
  v_policy jsonb := public.point_policy();
  v_balance integer := 0;
  v_points_cap integer := 0;
begin
  v_user_id := p_user_id;

  if p_is_guest then
    -- 게스트 경로: user_id 없이 진행. 호출자는 게스트 전용 RPC뿐.
    if v_user_id is not null then
      raise exception 'Guest order must not carry a user id';
    end if;
    if p_member_coupon_id is not null then
      raise exception '비회원 주문에는 쿠폰을 사용할 수 없습니다.';
    end if;
    if v_points > 0 then
      raise exception '비회원 주문에는 포인트를 사용할 수 없습니다.';
    end if;
    if nullif(btrim(coalesce(p_shipping_recipient_name, '')), '') is null then
      raise exception '주문자 이름을 입력해 주세요.';
    end if;
    v_phone_digits := regexp_replace(coalesce(p_shipping_recipient_phone, ''), '\D', '', 'g');
    if length(v_phone_digits) < 9 or length(v_phone_digits) > 11 then
      raise exception '휴대폰 번호를 정확히 입력해 주세요.';
    end if;

    -- 차단 회원의 게스트 우회 방어 (전화번호 대조 — best effort).
    select exists (
      select 1
      from public.member_profiles mp
      where coalesce(mp.is_blocked, false)
        and nullif(regexp_replace(coalesce(mp.phone, ''), '\D', '', 'g'), '') = v_phone_digits
    ) into v_blocked;
    if coalesce(v_blocked, false) then
      raise exception '주문을 진행할 수 없습니다. 고객센터로 문의해 주세요.';
    end if;
  else
    -- 회원 경로 (재정의 시에도 유지 필수)
    if v_user_id is null then
      raise exception 'Authentication required';
    end if;

    -- 차단 회원 가드 — service_role(finalize) 경로에서도 동작하도록 user_id 명시 조회
    select coalesce(mp.is_blocked, false) into v_blocked
    from public.member_profiles mp
    where mp.user_id = v_user_id;
    if coalesce(v_blocked, false) then
      raise exception '계정이 차단되어 해당 작업을 수행할 수 없습니다.';
    end if;
  end if;

  v_item_count := array_length(p_book_ids, 1);
  if v_item_count is null or v_item_count = 0 then
    raise exception 'At least one item is required';
  end if;
  if array_length(p_quantities, 1) <> v_item_count then
    raise exception 'book_ids and quantities must have same length';
  end if;

  for v_idx in 1..v_item_count loop
    if coalesce(p_quantities[v_idx], 0) <> 1 then
      raise exception '교재 한 권만 주문할 수 있습니다. (book_id=%, quantity=%)',
        p_book_ids[v_idx], p_quantities[v_idx];
    end if;

    select * into v_book from public.books
    where id = p_book_ids[v_idx] and status = 'on_sale' and is_public = true
    for update;
    if v_book is null then
      raise exception 'Book % is not available', p_book_ids[v_idx];
    end if;

    select count(*) into v_active_count
    from public.order_items oi
    inner join public.orders o on o.id = oi.order_id
    where oi.book_id = v_book.id
      and o.status not in ('cancelled', 'refunded');
    if v_active_count > 0 then
      raise exception 'Book % is already reserved by another order', v_book.id;
    end if;

    v_subtotal := v_subtotal + coalesce(v_book.price, 0);
  end loop;

  if v_subtotal >= v_free_shipping_threshold then
    v_shipping_fee := 0;
  end if;

  if p_member_coupon_id is not null then
    select * into v_member_coupon
    from public.member_coupons
    where id = p_member_coupon_id and user_id = v_user_id
    for update;
    if not found then
      raise exception '선택한 쿠폰을 찾을 수 없습니다.';
    end if;
    if v_member_coupon.status <> 'available' then
      raise exception '사용 가능한 쿠폰이 아닙니다.';
    end if;
    if v_member_coupon.expires_at is not null and v_member_coupon.expires_at < now() then
      raise exception '만료된 쿠폰입니다.';
    end if;

    select * into v_coupon from public.coupons where id = v_member_coupon.coupon_id;
    if not v_coupon.is_active then
      raise exception '비활성된 쿠폰입니다.';
    end if;
    if v_coupon.min_order_amount > v_subtotal then
      raise exception '최소 주문 금액(%원)을 만족하지 않습니다.', v_coupon.min_order_amount;
    end if;

    if v_coupon.usage_limit_per_user is not null then
      select count(*) into v_used_count from public.member_coupons mc2
      where mc2.user_id = v_user_id
        and mc2.coupon_id = v_coupon.id
        and mc2.status = 'used';
      if v_used_count >= v_coupon.usage_limit_per_user then
        raise exception '쿠폰 사용 한도를 초과했습니다.';
      end if;
    end if;

    if v_coupon.discount_type = 'fixed' then
      v_discount := least(v_coupon.discount_value, v_subtotal);
    elsif v_coupon.discount_type = 'percentage' then
      v_discount := (v_subtotal * v_coupon.discount_value) / 100;
      if v_coupon.max_discount_amount is not null then
        v_discount := least(v_discount, v_coupon.max_discount_amount);
      end if;
    elsif v_coupon.discount_type = 'free_shipping' then
      if v_subtotal >= v_free_shipping_threshold then
        raise exception '이 쿠폰은 무료배송 조건을 이미 충족한 주문엔 사용할 수 없습니다.';
      end if;
      v_discount := v_shipping_fee;
      v_shipping_fee := 0;
      v_is_free_shipping_coupon := true;
    end if;
  end if;

  -- 포인트 사용 검증 (회원 전용) — 정책: 1,000P 이상 보유 · 상품금액 15,000원 이상 · 상품금액 20%까지
  if v_points > 0 then
    v_balance := public.get_point_balance(v_user_id);
    if v_balance < (v_policy->>'min_balance_to_use')::integer then
      raise exception '포인트는 %P 이상 보유 시 사용할 수 있어요.', (v_policy->>'min_balance_to_use')::integer;
    end if;
    if v_points > v_balance then
      raise exception '보유 포인트(%P)보다 많이 사용할 수 없어요.', v_balance;
    end if;
    if v_subtotal < (v_policy->>'min_order_subtotal')::integer then
      raise exception '포인트는 상품금액 %원 이상 주문에서 사용할 수 있어요.', (v_policy->>'min_order_subtotal')::integer;
    end if;
    v_points_cap := floor(v_subtotal * (v_policy->>'max_use_ratio')::numeric)::integer;
    if v_is_free_shipping_coupon then
      v_points_cap := least(v_points_cap, v_subtotal);
    else
      v_points_cap := least(v_points_cap, greatest(v_subtotal - v_discount, 0));
    end if;
    if v_points > v_points_cap then
      raise exception '포인트는 이 주문에서 최대 %P까지 사용할 수 있어요.', v_points_cap;
    end if;
  end if;

  -- 제주·도서산간 추가비 — 무료배송(임계·쿠폰) 처리 "이후" 가산
  v_remote_surcharge := public.get_remote_area_surcharge(p_shipping_postal_code);
  v_shipping_fee := v_shipping_fee + v_remote_surcharge;

  if v_is_free_shipping_coupon then
    v_total_amount := v_subtotal + v_shipping_fee - v_points;
  else
    v_total_amount := v_subtotal + v_shipping_fee - v_discount - v_points;
  end if;
  if v_total_amount < 0 then v_total_amount := 0; end if;

  -- 검증 전용 모드: 어떤 쓰기도 없이 금액 견적만 반환 (결제 세션 생성용)
  if p_validate_only then
    return jsonb_build_object(
      'order_id', null,
      'order_number', null,
      'total_amount', v_total_amount,
      'subtotal', v_subtotal,
      'shipping_fee', v_shipping_fee,
      'remote_area_surcharge', v_remote_surcharge,
      'discount_amount', coalesce(v_discount, 0),
      'coupon_discount_amount', coalesce(v_discount, 0),
      'points_used', v_points
    );
  end if;

  v_order_number := coalesce(
    nullif(btrim(coalesce(p_order_number, '')), ''),
    case when p_is_guest
      then public.generate_guest_order_number()
      else public.generate_order_number()
    end
  );

  insert into public.orders (
    user_id, order_number, status,
    shipping_recipient_name, shipping_recipient_phone,
    shipping_postal_code, shipping_address_line1, shipping_address_line2, shipping_memo,
    payment_method, payment_status,
    subtotal, shipping_fee, discount_amount, total_amount, item_count,
    auto_confirm_at,
    applied_member_coupon_id, coupon_discount_amount,
    refund_bank_name, refund_account_number, refund_account_holder,
    guest_terms_agreed_at,
    points_used
  ) values (
    v_user_id, v_order_number, 'pending',
    p_shipping_recipient_name, p_shipping_recipient_phone,
    p_shipping_postal_code, p_shipping_address_line1, p_shipping_address_line2, p_shipping_memo,
    p_payment_method, 'pending',
    v_subtotal, v_shipping_fee, coalesce(v_discount, 0), v_total_amount, v_item_count,
    null,
    p_member_coupon_id,
    coalesce(v_discount, 0),
    nullif(btrim(coalesce(p_refund_bank, '')), ''),
    nullif(regexp_replace(coalesce(p_refund_account_number, ''), '[^0-9]', '', 'g'), ''),
    nullif(btrim(coalesce(p_refund_account_holder, '')), ''),
    case when p_is_guest then now() else null end,
    v_points
  ) returning id into v_order_id;

  for v_idx in 1..v_item_count loop
    select * into v_book from public.books where id = p_book_ids[v_idx];

    -- cover_image_url fallback — 식스샵 import 책은 products.cover_image_url에만 cover가 있음
    select p.cover_image_url into v_product_cover
    from public.products p
    where p.id = v_book.product_id;

    insert into public.order_items (
      order_id, book_id, product_id,
      title, option_label, condition_grade, cover_image_url,
      quantity, unit_price, total_price
    ) values (
      v_order_id, v_book.id, v_book.product_id,
      v_book.title, v_book.option, v_book.condition_grade,
      coalesce(
        nullif(btrim(v_book.cover_image_url), ''),
        nullif(btrim(v_product_cover), '')
      ),
      1, coalesce(v_book.price, 0),
      coalesce(v_book.price, 0)
    );
  end loop;

  if p_member_coupon_id is not null then
    update public.member_coupons
    set used_at = now(), used_order_id = v_order_id
    where id = p_member_coupon_id;
  end if;

  -- 포인트 소진 (lot FIFO) — 잔액 경합 시 여기서 예외 → 주문 전체 롤백
  if v_points > 0 then
    perform public.consume_points_for_order(v_user_id, v_order_id, v_points);
  end if;

  -- 서버 카트 정리는 회원 전용
  if not p_is_guest then
    delete from public.cart_items
    where user_id = v_user_id and book_id = any(p_book_ids);
  end if;

  return jsonb_build_object(
    'order_id', v_order_id,
    'order_number', v_order_number,
    'total_amount', v_total_amount,
    'subtotal', v_subtotal,
    'shipping_fee', v_shipping_fee,
    'remote_area_surcharge', v_remote_surcharge,
    'discount_amount', coalesce(v_discount, 0),
    'coupon_discount_amount', coalesce(v_discount, 0),
    'points_used', v_points
  );
end;
$function$;

revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean, integer
) from public;
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean, integer
) from anon;
revoke all on function public.create_order_core(
  uuid, bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, text, boolean, boolean, integer
) from authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) 회원 래퍼 RPC 재정의 — p_points_amount 추가 (옛 13인자 시그니처 drop)
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
);

create or replace function public.create_order(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'bank_transfer'::text,
  p_member_coupon_id bigint default null::bigint,
  p_refund_bank text default null,
  p_refund_account_number text default null,
  p_refund_account_holder text default null,
  p_points_amount integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  return public.create_order_core(
    v_user_id,
    p_book_ids,
    p_quantities,
    p_shipping_recipient_name,
    p_shipping_recipient_phone,
    p_shipping_postal_code,
    p_shipping_address_line1,
    p_shipping_address_line2,
    p_shipping_memo,
    p_payment_method,
    p_member_coupon_id,
    p_refund_bank,
    p_refund_account_number,
    p_refund_account_holder,
    p_points_amount => coalesce(p_points_amount, 0)
  );
end;
$function$;

revoke all on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, integer
) from public;
revoke all on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, integer
) from anon;
grant execute on function public.create_order(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, integer
) to authenticated;

drop function if exists public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text
);

create or replace function public.create_pg_checkout_session(
  p_book_ids bigint[],
  p_quantities integer[],
  p_shipping_recipient_name text,
  p_shipping_recipient_phone text,
  p_shipping_postal_code text,
  p_shipping_address_line1 text,
  p_shipping_address_line2 text,
  p_shipping_memo text,
  p_payment_method text default 'card'::text,
  p_member_coupon_id bigint default null::bigint,
  p_refund_bank text default null,
  p_refund_account_number text default null,
  p_refund_account_holder text default null,
  p_points_amount integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
  v_quote jsonb;
  v_order_number text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  if coalesce(p_payment_method, 'bank_transfer') = 'bank_transfer' then
    raise exception 'PG 결제 수단만 결제 세션을 사용할 수 있습니다.';
  end if;

  -- create_order와 동일한 검증·금액 계산 (쓰기 없음). 포인트 잔액도 여기서 1차 검증,
  -- 실제 차감은 finalize(주문 실체화) 시점.
  v_quote := public.create_order_core(
    v_user_id,
    p_book_ids,
    p_quantities,
    p_shipping_recipient_name,
    p_shipping_recipient_phone,
    p_shipping_postal_code,
    p_shipping_address_line1,
    p_shipping_address_line2,
    p_shipping_memo,
    p_payment_method,
    p_member_coupon_id,
    p_refund_bank,
    p_refund_account_number,
    p_refund_account_holder,
    p_order_number => null,
    p_validate_only => true,
    p_points_amount => coalesce(p_points_amount, 0)
  );

  v_order_number := public.generate_order_number();

  insert into public.pg_checkout_sessions (order_number, user_id, payload, expected_amount)
  values (
    v_order_number,
    v_user_id,
    jsonb_build_object(
      'book_ids', to_jsonb(p_book_ids),
      'quantities', to_jsonb(p_quantities),
      'shipping_recipient_name', p_shipping_recipient_name,
      'shipping_recipient_phone', p_shipping_recipient_phone,
      'shipping_postal_code', p_shipping_postal_code,
      'shipping_address_line1', p_shipping_address_line1,
      'shipping_address_line2', p_shipping_address_line2,
      'shipping_memo', p_shipping_memo,
      'payment_method', p_payment_method,
      'member_coupon_id', p_member_coupon_id,
      'refund_bank', p_refund_bank,
      'refund_account_number', p_refund_account_number,
      'refund_account_holder', p_refund_account_holder,
      'points_amount', coalesce(p_points_amount, 0)
    ),
    coalesce((v_quote->>'total_amount')::integer, 0)
  );

  return v_quote || jsonb_build_object(
    'order_number', v_order_number,
    'checkout_session', true
  );
end;
$function$;

revoke all on function public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, integer
) from public;
revoke all on function public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, integer
) from anon;
grant execute on function public.create_pg_checkout_session(
  bigint[], integer[], text, text, text, text, text, text, text, bigint, text, text, text, integer
) to authenticated;

-- finalize — 세션 payload의 points_amount를 core에 전달 (본문은 20260803061500과 동일)
create or replace function public.finalize_pg_checkout_session(
  p_order_number text,
  p_amount integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_session record;
  v_order record;
  v_result jsonb;
begin
  if p_order_number is null or btrim(p_order_number) = '' then
    return jsonb_build_object('success', false, 'reason', 'order_number_required');
  end if;

  select * into v_session
  from public.pg_checkout_sessions
  where order_number = p_order_number
  for update;

  if not found then
    return jsonb_build_object('success', false, 'reason', 'session_not_found');
  end if;

  -- 멱등 처리: 중복 POST면 이미 실체화된 주문 현황 반환
  if v_session.status = 'completed' then
    select * into v_order from public.orders where id = v_session.order_id;
    if not found then
      return jsonb_build_object('success', false, 'reason', 'order_missing');
    end if;
    return jsonb_build_object(
      'success', true,
      'already_completed', true,
      'order_id', v_order.id,
      'order_number', v_order.order_number,
      'total_amount', v_order.total_amount,
      'order_status', v_order.status,
      'payment_status', v_order.payment_status
    );
  end if;

  if v_session.created_at < now() - interval '24 hours' then
    return jsonb_build_object('success', false, 'reason', 'session_expired');
  end if;

  if p_amount is null or p_amount <> v_session.expected_amount then
    return jsonb_build_object(
      'success', false,
      'reason', 'amount_mismatch',
      'expected_amount', v_session.expected_amount
    );
  end if;

  -- 세션 스냅샷으로 주문 실체화 — 재고·쿠폰·포인트·가격은 이 시점에 전부 재검증
  v_result := public.create_order_core(
    v_session.user_id,
    (
      select coalesce(array_agg(t.value::bigint order by t.ord), array[]::bigint[])
      from jsonb_array_elements_text(v_session.payload->'book_ids') with ordinality as t(value, ord)
    ),
    (
      select coalesce(array_agg(t.value::integer order by t.ord), array[]::integer[])
      from jsonb_array_elements_text(v_session.payload->'quantities') with ordinality as t(value, ord)
    ),
    v_session.payload->>'shipping_recipient_name',
    v_session.payload->>'shipping_recipient_phone',
    v_session.payload->>'shipping_postal_code',
    v_session.payload->>'shipping_address_line1',
    v_session.payload->>'shipping_address_line2',
    v_session.payload->>'shipping_memo',
    coalesce(v_session.payload->>'payment_method', 'card'),
    nullif(v_session.payload->>'member_coupon_id', '')::bigint,
    v_session.payload->>'refund_bank',
    v_session.payload->>'refund_account_number',
    v_session.payload->>'refund_account_holder',
    p_order_number => v_session.order_number,
    p_validate_only => false,
    p_is_guest => (v_session.user_id is null),
    p_points_amount => coalesce(nullif(v_session.payload->>'points_amount', '')::integer, 0)
  );

  if coalesce((v_result->>'total_amount')::integer, -1) <> p_amount then
    raise exception '주문 금액(%원)이 결제 예정 금액(%원)과 일치하지 않습니다.',
      coalesce((v_result->>'total_amount')::integer, 0), p_amount;
  end if;

  update public.pg_checkout_sessions
     set status = 'completed',
         order_id = (v_result->>'order_id')::bigint,
         updated_at = now()
   where id = v_session.id;

  return jsonb_build_object(
    'success', true,
    'already_completed', false,
    'order_id', (v_result->>'order_id')::bigint,
    'order_number', v_session.order_number,
    'total_amount', (v_result->>'total_amount')::integer,
    'order_status', 'pending',
    'payment_status', 'pending'
  );
end;
$function$;

revoke all on function public.finalize_pg_checkout_session(text, integer) from public;
revoke all on function public.finalize_pg_checkout_session(text, integer) from anon;
revoke all on function public.finalize_pg_checkout_session(text, integer) from authenticated;
grant execute on function public.finalize_pg_checkout_session(text, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) 후기 작성 시 적립 — create_review 재정의 (20260902080505 본문 + 적립 블록)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.create_review(
  p_order_id bigint,
  p_rating integer,
  p_content text,
  p_photo_urls text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_order record;
  v_items record;
  v_input record;
  v_review public.reviews%rowtype;
  v_policy jsonb := public.point_policy();
  v_earn integer := 0;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  perform public.assert_member_not_blocked();

  select o.id, o.status
  into v_order
  from public.orders o
  where o.id = p_order_id
    and o.user_id = v_user_id
  limit 1;

  if not found then
    raise exception '주문을 찾을 수 없어요.';
  end if;
  if v_order.status <> 'confirmed' then
    raise exception '구매확정 후에 후기를 작성할 수 있어요.';
  end if;
  if exists (select 1 from public.reviews r where r.order_id = p_order_id) then
    raise exception '이미 후기를 작성한 주문이에요.';
  end if;

  select * into v_input
  from public.normalize_review_input(v_user_id, p_rating, p_content, p_photo_urls);

  select
    (array_agg(oi.title order by oi.id))[1] as primary_title,
    (array_agg(oi.product_id order by oi.id) filter (where oi.product_id is not null))[1] as primary_product_id,
    coalesce(array_agg(distinct oi.product_id) filter (where oi.product_id is not null), '{}'::bigint[]) as product_ids,
    coalesce(sum(greatest(coalesce(oi.quantity, 1), 1)), 0)::integer as item_count
  into v_items
  from public.order_items oi
  where oi.order_id = p_order_id
    and oi.refunded_at is null;

  if v_items.item_count is null or v_items.item_count < 1 or v_items.primary_title is null then
    raise exception '환불된 주문에는 후기를 남길 수 없어요.';
  end if;

  insert into public.reviews (
    user_id, order_id, rating, content, photo_urls,
    product_ids, primary_product_id, primary_title, item_count
  ) values (
    v_user_id, p_order_id, v_input.rating, v_input.content, v_input.photo_urls,
    v_items.product_ids, v_items.primary_product_id, v_items.primary_title, v_items.item_count
  )
  returning * into v_review;

  -- 포인트 적립: 사진 있으면 1,000P, 글만이면 500P (12개월 유효)
  v_earn := case
    when coalesce(cardinality(v_review.photo_urls), 0) > 0 then (v_policy->>'earn_photo')::integer
    else (v_policy->>'earn_text')::integer
  end;
  perform public.grant_points(
    v_user_id, v_earn, 'review', 'review_earn',
    p_review_id => v_review.id,
    p_order_id => p_order_id,
    p_note => case when coalesce(cardinality(v_review.photo_urls), 0) > 0 then '사진 후기 작성' else '후기 작성' end
  );

  return jsonb_build_object(
    'id', v_review.id,
    'order_id', v_review.order_id,
    'rating', v_review.rating,
    'content', v_review.content,
    'photo_urls', to_jsonb(v_review.photo_urls),
    'product_title', v_review.primary_title,
    'item_count', v_review.item_count,
    'is_hidden', v_review.is_hidden,
    'created_at', v_review.created_at,
    'updated_at', v_review.updated_at,
    'earned_points', v_earn
  );
end;
$$;

-- 어드민 숨김 시 적립 회수 (해제해도 재적립하지 않음)
create or replace function public.admin_set_review_hidden(
  p_review_id bigint,
  p_hidden boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review public.reviews%rowtype;
  v_reclaimed integer := 0;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  update public.reviews
  set is_hidden = coalesce(p_hidden, false),
      hidden_reason = case when coalesce(p_hidden, false) then nullif(btrim(coalesce(p_reason, '')), '') else null end,
      hidden_at = case when coalesce(p_hidden, false) then now() else null end
  where id = p_review_id
  returning * into v_review;

  if v_review.id is null then
    raise exception '후기를 찾을 수 없습니다. (id=%)', p_review_id;
  end if;

  if coalesce(p_hidden, false) then
    v_reclaimed := public.reclaim_review_points(p_review_id, '후기 숨김 처리');
  end if;

  return jsonb_build_object(
    'id', v_review.id,
    'is_hidden', v_review.is_hidden,
    'hidden_reason', v_review.hidden_reason,
    'hidden_at', v_review.hidden_at,
    'reclaimed_points', v_reclaimed
  );
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8) 회원 조회 RPC — 잔액·정책·내역·소멸 예정
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.get_my_points(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  return jsonb_build_object(
    'balance', public.get_point_balance(v_user_id),
    'policy', public.point_policy(),
    'expiring_within_30_days', (
      select coalesce(sum(remaining), 0)
      from public.point_lots
      where user_id = v_user_id and voided_at is null and remaining > 0
        and expires_at > now() and expires_at <= now() + interval '30 days'
    ),
    'next_expiry_at', (
      select min(expires_at)
      from public.point_lots
      where user_id = v_user_id and voided_at is null and remaining > 0 and expires_at > now()
    ),
    'transactions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'amount', t.amount,
        'kind', t.kind,
        'note', t.note,
        'order_id', t.order_id,
        'order_number', o.order_number,
        'review_id', t.review_id,
        'created_at', t.created_at,
        'expires_at', l.expires_at
      ) order by t.created_at desc, t.id desc)
      from (
        select * from public.point_transactions
        where user_id = v_user_id
        order by created_at desc, id desc
        limit v_limit
      ) t
      left join public.orders o on o.id = t.order_id
      left join public.point_lots l on l.id = t.lot_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_my_points(integer) from public;
revoke all on function public.get_my_points(integer) from anon;
grant execute on function public.get_my_points(integer) to authenticated;

-- get_my_orders — points_used 추가 (20260731185933 본문 + 1필드)
create or replace function public.get_my_orders(
  p_limit integer default 20,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      'shipping_recipient_name', o.shipping_recipient_name,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      'discount_amount', o.discount_amount,
      'coupon_discount_amount', o.coupon_discount_amount,
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'points_used', coalesce(o.points_used, 0),
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      'refunded_amount', o.refunded_amount,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'product_id', oi.product_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', coalesce(
            nullif(btrim(oi.cover_image_url), ''),
            nullif(btrim(p.cover_image_url), '')
          ),
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount
        ) order by oi.id)
        from public.order_items oi
        left join public.products p on p.id = oi.product_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    where o.user_id = v_user_id
    order by o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9) 어드민 — 회원 포인트 조회·수동 조정
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_get_member_points(p_user_id uuid, p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  return jsonb_build_object(
    'balance', public.get_point_balance(p_user_id),
    'transactions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'amount', t.amount, 'kind', t.kind, 'note', t.note,
        'order_id', t.order_id, 'order_number', o.order_number,
        'review_id', t.review_id, 'created_at', t.created_at, 'expires_at', l.expires_at
      ) order by t.created_at desc, t.id desc)
      from (
        select * from public.point_transactions where user_id = p_user_id
        order by created_at desc, id desc limit least(greatest(coalesce(p_limit, 50), 1), 200)
      ) t
      left join public.orders o on o.id = t.order_id
      left join public.point_lots l on l.id = t.lot_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.admin_get_member_points(uuid, integer) from public;
revoke all on function public.admin_get_member_points(uuid, integer) from anon;
grant execute on function public.admin_get_member_points(uuid, integer) to authenticated;

-- 양수 = 수동 적립(12개월 유효), 음수 = 잔여 lot에서 차감(만료 임박순). 사유 필수.
create or replace function public.admin_adjust_points(p_user_id uuid, p_amount integer, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_left integer;
  v_lot record;
  v_take integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if p_user_id is null or coalesce(p_amount, 0) = 0 then
    raise exception '회원과 0이 아닌 금액이 필요합니다.';
  end if;
  if v_note is null then
    raise exception '조정 사유를 입력해 주세요.';
  end if;
  if not exists (select 1 from public.member_profiles where user_id = p_user_id) then
    raise exception '회원을 찾을 수 없습니다.';
  end if;

  if p_amount > 0 then
    perform public.grant_points(p_user_id, p_amount, 'admin', 'admin_adjust', p_note => v_note);
  else
    v_left := -p_amount;
    for v_lot in
      select id, remaining from public.point_lots
      where user_id = p_user_id and voided_at is null and expires_at > now() and remaining > 0
      order by expires_at, id
      for update
    loop
      exit when v_left <= 0;
      v_take := least(v_lot.remaining, v_left);
      update public.point_lots set remaining = remaining - v_take where id = v_lot.id;
      v_left := v_left - v_take;
    end loop;
    if v_left > 0 then
      raise exception '잔액보다 많이 차감할 수 없습니다. (잔액 %P)', public.get_point_balance(p_user_id);
    end if;
    insert into public.point_transactions (user_id, amount, kind, note)
    values (p_user_id, p_amount, 'admin_adjust', v_note);
  end if;

  return jsonb_build_object('balance', public.get_point_balance(p_user_id));
end;
$$;

revoke all on function public.admin_adjust_points(uuid, integer, text) from public;
revoke all on function public.admin_adjust_points(uuid, integer, text) from anon;
grant execute on function public.admin_adjust_points(uuid, integer, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10) list_admin_orders — points_used 추가 (20260824070040 본문 + 1필드, 스크립트 복제)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_admin_orders(
  p_search text default null::text,
  p_statuses text[] default null::text[],
  p_from_date date default null::date,
  p_to_date date default null::date,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_items jsonb;
  v_total integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select count(*)::integer
  into v_total
  from public.orders o
  left join public.member_profiles p on p.user_id = o.user_id
  where
    (p_search is null or p_search = '' or
      o.order_number ilike '%' || p_search || '%' or
      p.name ilike '%' || p_search || '%' or
      p.email ilike '%' || p_search || '%' or
      p.phone ilike '%' || p_search || '%' or
      o.shipping_recipient_name ilike '%' || p_search || '%' or
      o.shipping_recipient_phone ilike '%' || p_search || '%')
    and (p_statuses is null or o.status = any(p_statuses))
    and (p_from_date is null or o.created_at >= p_from_date)
    and (p_to_date is null or o.created_at < p_to_date + interval '1 day');

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'status', o.status,
      'payment_method', o.payment_method,
      'payment_status', o.payment_status,
      -- 결제 확인 시각 2종 (2026-07-13: 무통장=paid_at, 레거시 PG=pg_approved_at 폴백)
      'paid_at', o.paid_at,
      'pg_approved_at', o.pg_approved_at,
      'subtotal', o.subtotal,
      'shipping_fee', o.shipping_fee,
      -- 할인 필드 3종 (2026-07-06 피드백: 주문 상세에 쿠폰 사용액 표시)
      'discount_amount', o.discount_amount,
      'coupon_discount_amount', o.coupon_discount_amount,
      -- 포인트 사용액 (2026-09-02 포인트 제도 — total_amount에 이미 차감 반영)
      'points_used', coalesce(o.points_used, 0),
      'applied_member_coupon_id', o.applied_member_coupon_id,
      'total_amount', o.total_amount,
      'item_count', o.item_count,
      'tracking_number', o.tracking_number,
      'tracking_carrier', o.tracking_carrier,
      'shipping_recipient_name', o.shipping_recipient_name,
      'shipping_recipient_phone', o.shipping_recipient_phone,
      'shipping_postal_code', o.shipping_postal_code,
      'shipping_address_line1', o.shipping_address_line1,
      'shipping_address_line2', o.shipping_address_line2,
      'shipping_memo', o.shipping_memo,
      'confirmed_at', o.confirmed_at,
      'auto_confirm_at', o.auto_confirm_at,
      'created_at', o.created_at,
      'updated_at', o.updated_at,
      -- 환불 메타 4종
      'refund_requested_at', o.refund_requested_at,
      'refund_request_reason', o.refund_request_reason,
      'refunded_at', o.refunded_at,
      'refund_reason', o.refund_reason,
      -- 환불 신청 해소 시각 (2026-08-24 자동확정 보류 — null이면 확정·송금 보류 중)
      'refund_request_resolved_at', o.refund_request_resolved_at,
      -- 환불 누계 (2026-08-01 품목별 부분환불 — 잔액 = total_amount - refunded_amount)
      'refunded_amount', o.refunded_amount,
      -- 환불계좌 3종 (무통장 수동 환불용 — 주문 시 구매자 입력)
      'refund_bank_name', o.refund_bank_name,
      'refund_account_number', o.refund_account_number,
      'refund_account_holder', o.refund_account_holder,
      -- 반품 수거 3종 (2026-08-24 반품 수거 자동화 — cust_use_no는 서버 전용이라 미노출)
      'return_tracking_number', o.return_tracking_number,
      'return_registered_at', o.return_registered_at,
      'return_recovered_at', o.return_recovered_at,
      -- ⚠ user_id는 알림 mirror용 (send-notification.js의 recipientUserId).
      --   미노출 시 사이트 내 알림이 통째로 skip됐었음.
      'user_id', o.user_id,
      -- 비회원 주문 여부 (2026-08-03 게스트 주문 도입)
      'is_guest', (o.user_id is null),
      'buyer_email', p.email,
      'buyer_name', p.name,
      'buyer_phone', p.phone,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', oi.id,
          'book_id', oi.book_id,
          'title', oi.title,
          'option_label', oi.option_label,
          'condition_grade', oi.condition_grade,
          'cover_image_url', oi.cover_image_url,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price,
          'total_price', oi.total_price,
          -- 품목별 환불 상태 (2026-08-01 부분환불)
          'refunded_at', oi.refunded_at,
          'refund_amount', oi.refund_amount,
          'refund_reason', oi.refund_reason,
          -- 재입고 보류 (2026-08-24 반품 수거 — 실물 회수 전 재노출 방지)
          'restock_held_at', oi.restock_held_at,
          -- 피킹 동선용 재고 메타 (2026-07-18: 위치로 가서 일련번호로 실물 확인)
          'book_serial_number', b.serial_number,
          'book_location', b.location,
          'book_status', b.status
        ) order by oi.id)
        from public.order_items oi
        left join public.books b on b.id = oi.book_id
        where oi.order_id = o.id
      ), '[]'::jsonb)
    ) as row_data
    from public.orders o
    left join public.member_profiles p on p.user_id = o.user_id
    where
      (p_search is null or p_search = '' or
        o.order_number ilike '%' || p_search || '%' or
        p.name ilike '%' || p_search || '%' or
        p.email ilike '%' || p_search || '%' or
        p.phone ilike '%' || p_search || '%' or
        o.shipping_recipient_name ilike '%' || p_search || '%' or
        o.shipping_recipient_phone ilike '%' || p_search || '%')
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_from_date is null or o.created_at >= p_from_date)
      and (p_to_date is null or o.created_at < p_to_date + interval '1 day')
    order by
      -- 미해소 환불 신청 최우선 (해소된 신청은 일반 정렬)
      (case
        when o.refund_requested_at is not null
         and o.refund_request_resolved_at is null
         and o.status <> 'refunded' then 0
        else 1
      end),
      o.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return jsonb_build_object('items', v_items, 'total_count', v_total);
end;
$function$;

commit;

notify pgrst, 'reload schema';
