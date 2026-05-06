-- 쿠폰 시스템 PR 2: 회원 보유 쿠폰(member_coupons) + 발급/조회 RPC
-- 정책 (PR 1 합의 사항):
--  - admin_assigned 쿠폰은 어드민이 같은 회원에게 여러 매 발급 가능
--  - code/download 쿠폰은 한 사람당 1매만 (자율 selff-claim 또는 admin push 모두 동일)
--  - usage_limit_per_user는 사용 시점에 검증 (PR 3)
--  - total_quantity 초과 시 발급 거부 (atomic with row lock)

-- ── member_coupons: 회원별 보유 쿠폰 ──────────────────────────────
create table if not exists public.member_coupons (
  id bigint generated always as identity primary key,
  coupon_id bigint not null references public.coupons(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  issued_at timestamptz not null default now(),
  -- 발급 시 coupons.valid_until 복사. null이면 무기한.
  expires_at timestamptz null,
  used_at timestamptz null,
  used_order_id bigint null references public.orders(id) on delete set null,
  status text not null default 'available'
    check (status in ('available', 'used', 'expired')),
  created_at timestamptz not null default now()
);

create index if not exists idx_member_coupons_user_status
  on public.member_coupons (user_id, status, expires_at);

create index if not exists idx_member_coupons_coupon_user
  on public.member_coupons (coupon_id, user_id);

-- used_at 설정 시 자동 status='used'
create or replace function public.tg_member_coupons_status_on_use()
returns trigger
language plpgsql
as $$
begin
  if new.used_at is not null and (old.used_at is null or old.used_at <> new.used_at) then
    new.status = 'used';
  end if;
  return new;
end;
$$;

drop trigger if exists tg_member_coupons_status on public.member_coupons;
create trigger tg_member_coupons_status
  before update on public.member_coupons
  for each row execute function public.tg_member_coupons_status_on_use();

-- ── RLS ───────────────────────────────────────────────────────
alter table public.member_coupons enable row level security;

drop policy if exists member_coupons_select_own on public.member_coupons;
create policy member_coupons_select_own on public.member_coupons
  for select
  using (auth.uid() = user_id);

drop policy if exists member_coupons_admin_all on public.member_coupons;
create policy member_coupons_admin_all on public.member_coupons
  for all
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ── 회원 RPC ──────────────────────────────────────────────────

-- 본인 보유 쿠폰. expires_at < now()이면 status가 'available'이라도 effective_status='expired'.
-- p_status_filter: 'all' | 'available' | 'used' | 'expired'
create or replace function public.get_member_coupons(p_status_filter text default 'all')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'issued_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', mc.id,
      'coupon_id', mc.coupon_id,
      'issued_at', mc.issued_at,
      'expires_at', mc.expires_at,
      'used_at', mc.used_at,
      'effective_status', case
        when mc.status = 'used' then 'used'
        when mc.status = 'expired' then 'expired'
        when mc.expires_at is not null and mc.expires_at < now() then 'expired'
        else 'available'
      end,
      'title', c.title,
      'description', c.description,
      'discount_type', c.discount_type,
      'discount_value', c.discount_value,
      'max_discount_amount', c.max_discount_amount,
      'min_order_amount', c.min_order_amount,
      'issuance_type', c.issuance_type
    ) as row_data
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    where mc.user_id = v_user_id
      and (
        p_status_filter = 'all'
        or (p_status_filter = 'available'
            and mc.status = 'available'
            and (mc.expires_at is null or mc.expires_at >= now()))
        or (p_status_filter = 'used' and mc.status = 'used')
        or (p_status_filter = 'expired'
            and (mc.status = 'expired'
              or (mc.status = 'available' and mc.expires_at is not null and mc.expires_at < now())))
      )
    order by mc.issued_at desc
  ) sub;

  return v_result;
end;
$$;

-- 다운로드 가능한 쿠폰 (다운로드형 + 활성 + 본인 미보유)
create or replace function public.get_downloadable_coupons()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select to_jsonb(c.*) as row_data
    from public.coupons c
    where c.issuance_type = 'download'
      and c.is_active = true
      and (c.valid_from is null or c.valid_from <= now())
      and (c.valid_until is null or c.valid_until >= now())
      and (c.total_quantity is null or c.issued_count < c.total_quantity)
      and not exists (
        select 1 from public.member_coupons mc
        where mc.coupon_id = c.id and mc.user_id = v_user_id
      )
    order by c.created_at desc
  ) sub;

  return v_result;
end;
$$;

-- 코드 입력으로 발급 (case-insensitive 매칭)
create or replace function public.claim_coupon_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_coupon record;
  v_member_coupon_id bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_code is null or btrim(p_code) = '' then
    raise exception '쿠폰 코드를 입력해 주세요.';
  end if;

  select * into v_coupon
  from public.coupons
  where lower(code) = lower(btrim(p_code))
  for update;

  if not found then
    raise exception '유효하지 않은 쿠폰 코드입니다.';
  end if;

  if v_coupon.issuance_type <> 'code' then
    raise exception '코드 입력 가능한 쿠폰이 아닙니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰입니다.';
  end if;
  if v_coupon.valid_from is not null and v_coupon.valid_from > now() then
    raise exception '아직 사용할 수 없는 쿠폰입니다.';
  end if;
  if v_coupon.valid_until is not null and v_coupon.valid_until < now() then
    raise exception '만료된 쿠폰입니다.';
  end if;
  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    raise exception '발급 한도를 초과했습니다.';
  end if;
  if exists (
    select 1 from public.member_coupons
    where coupon_id = v_coupon.id and user_id = v_user_id
  ) then
    raise exception '이미 등록된 쿠폰입니다.';
  end if;

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (v_coupon.id, v_user_id, v_coupon.valid_until)
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = v_coupon.id;

  return jsonb_build_object('success', true, 'member_coupon_id', v_member_coupon_id);
end;
$$;

-- 다운로드형 쿠폰 받기
create or replace function public.claim_coupon_for_download(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_coupon record;
  v_member_coupon_id bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;
  if v_coupon.issuance_type <> 'download' then
    raise exception '다운로드 가능한 쿠폰이 아닙니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰입니다.';
  end if;
  if v_coupon.valid_from is not null and v_coupon.valid_from > now() then
    raise exception '아직 사용할 수 없는 쿠폰입니다.';
  end if;
  if v_coupon.valid_until is not null and v_coupon.valid_until < now() then
    raise exception '만료된 쿠폰입니다.';
  end if;
  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    raise exception '발급 한도를 초과했습니다.';
  end if;
  if exists (
    select 1 from public.member_coupons
    where coupon_id = v_coupon.id and user_id = v_user_id
  ) then
    raise exception '이미 받은 쿠폰입니다.';
  end if;

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (v_coupon.id, v_user_id, v_coupon.valid_until)
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = v_coupon.id;

  return jsonb_build_object('success', true, 'member_coupon_id', v_member_coupon_id);
end;
$$;

-- ── 어드민 RPC ────────────────────────────────────────────────

-- 특정 회원에게 1매 발급
create or replace function public.admin_issue_coupon_to_user(
  p_coupon_id bigint,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_member_coupon_id bigint;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception '회원을 찾을 수 없습니다.';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰은 발급할 수 없습니다.';
  end if;
  if v_coupon.total_quantity is not null and v_coupon.issued_count >= v_coupon.total_quantity then
    raise exception '발급 한도를 초과했습니다.';
  end if;

  -- code/download형은 한 사람당 1매 제한 (admin이 push해도 동일 정책)
  if v_coupon.issuance_type in ('code', 'download') then
    if exists (
      select 1 from public.member_coupons
      where coupon_id = p_coupon_id and user_id = p_user_id
    ) then
      raise exception '이 회원은 이미 이 쿠폰을 가지고 있습니다.';
    end if;
  end if;

  insert into public.member_coupons (coupon_id, user_id, expires_at)
  values (p_coupon_id, p_user_id, v_coupon.valid_until)
  returning id into v_member_coupon_id;

  update public.coupons set issued_count = issued_count + 1 where id = p_coupon_id;

  return jsonb_build_object('success', true, 'member_coupon_id', v_member_coupon_id);
end;
$$;

-- 활성 회원 전체에 1매씩 발급 (admin_users 제외, code/download형은 미보유 회원만)
create or replace function public.admin_issue_coupon_to_all(p_coupon_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_inserted integer;
  v_remaining integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select * into v_coupon from public.coupons where id = p_coupon_id for update;
  if not found then
    raise exception '쿠폰을 찾을 수 없습니다.';
  end if;
  if not v_coupon.is_active then
    raise exception '비활성된 쿠폰은 발급할 수 없습니다.';
  end if;

  if v_coupon.total_quantity is null then
    v_remaining := 1000000;  -- 사실상 무제한
  else
    v_remaining := v_coupon.total_quantity - v_coupon.issued_count;
    if v_remaining <= 0 then
      raise exception '발급 한도를 초과했습니다.';
    end if;
  end if;

  with eligible as (
    select mp.user_id
    from public.member_profiles mp
    where not exists (
      select 1 from public.admin_users au
      where lower(au.email) = lower(mp.email)
    )
    and (
      v_coupon.issuance_type not in ('code', 'download')
      or not exists (
        select 1 from public.member_coupons mc
        where mc.coupon_id = p_coupon_id and mc.user_id = mp.user_id
      )
    )
    limit v_remaining
  )
  insert into public.member_coupons (coupon_id, user_id, expires_at)
  select p_coupon_id, user_id, v_coupon.valid_until
  from eligible;

  get diagnostics v_inserted = row_count;

  if v_inserted > 0 then
    update public.coupons set issued_count = issued_count + v_inserted where id = p_coupon_id;
  end if;

  return jsonb_build_object('success', true, 'inserted_count', v_inserted);
end;
$$;

-- 어드민: 특정 쿠폰의 발급 이력
create or replace function public.admin_list_member_coupons(
  p_coupon_id bigint,
  p_limit integer default 200,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  select coalesce(jsonb_agg(row_data order by row_data->>'issued_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', mc.id,
      'user_id', mc.user_id,
      'email', mp.email,
      'name', mp.name,
      'nickname', mp.nickname,
      'issued_at', mc.issued_at,
      'expires_at', mc.expires_at,
      'used_at', mc.used_at,
      'used_order_id', mc.used_order_id,
      'status', case
        when mc.status = 'used' then 'used'
        when mc.status = 'expired' then 'expired'
        when mc.expires_at is not null and mc.expires_at < now() then 'expired'
        else 'available'
      end
    ) as row_data
    from public.member_coupons mc
    left join public.member_profiles mp on mp.user_id = mc.user_id
    where mc.coupon_id = p_coupon_id
    order by mc.issued_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;

grant execute on function public.get_member_coupons(text) to authenticated;
grant execute on function public.get_downloadable_coupons() to authenticated;
grant execute on function public.claim_coupon_by_code(text) to authenticated;
grant execute on function public.claim_coupon_for_download(bigint) to authenticated;
grant execute on function public.admin_issue_coupon_to_user(bigint, uuid) to authenticated;
grant execute on function public.admin_issue_coupon_to_all(bigint) to authenticated;
grant execute on function public.admin_list_member_coupons(bigint, integer, integer) to authenticated;
