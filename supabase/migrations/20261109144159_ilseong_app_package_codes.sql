-- 일성월심 앱 패키지 코드 발급 (2026-11-09)
--
-- 일성월심 학습지(4과목 × 8주 패키지)를 자체 판매 상품으로 팔고, 결제가 확인되면 일성월심 앱 서버에서
-- 주문 줄마다 앱 코드를 받아 저장·알림톡 발송한다. 앱 서버 호출·알림 발송은 admin-web 크론
-- (/api/admin/ilseong-app-codes)이 맡고, DB는 대기열과 상태만 관리한다.
--
-- 기본 꺼짐:
--   · ilseong_app_settings.sales_enabled 기본 false. 꺼져 있으면 앱 패키지 상품은 공개(is_listed=true)할 수 없다.
--     켜기는 admin-web 서버가 ILSEONG_API_BASE_URL·ILSEONG_PARTNER_SECRET 설정을 확인한 뒤에만 한다(service_role 전용 RPC).
--   · 앱 패키지로 지정한 상품이 없으면 아래 트리거는 아무것도 하지 않는다. 기존 상품의 주문·결제·알림 흐름 불변.
--
-- 더하기만: 새 테이블 4개, 새 함수, 새 트리거. 기존 테이블·열·함수는 바꾸지 않는다.
--
-- 코드 원문(order_app_codes.code) 읽기: 주문한 회원 본인(RLS), 비회원은 get_guest_order_app_codes(주문번호+휴대폰 인증),
-- 서버(service_role). 관리자 화면은 서버가 가린 코드만 받는다. 공개 열·알림 로그에 원문을 두지 않는다.
--
-- ⚠ 재정의 시 유지 필수:
--   · 트리거 함수의 exception 삼킴 — 대기열 실패가 결제 확인·환불 처리를 막으면 안 된다.
--   · ilseong_app_guard_product_listing — 판매가 꺼져 있으면 앱 패키지 상품 공개 거부.
--   · get_guest_order_app_codes — get_guest_order와 같은 인증·실패 횟수 제한.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. 설정 (한 줄)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.ilseong_app_settings (
  id smallint primary key default 1 check (id = 1),
  -- 판매 켜짐. 앱 서버 연결 설정(환경 변수)이 있을 때만 admin-web 서버가 켠다.
  sales_enabled boolean not null default false,
  -- 환불 시 앱 코드 처리 [권고안, 바꿀 수 있음]
  --   revoke_access     : 등록 전 코드 폐기 + 등록한 코드의 앱 이용도 종료 (기본)
  --   revoke_unredeemed : 등록 전 코드만 폐기, 이미 등록한 앱 이용은 유지
  --   none              : 앱 서버에 폐기 요청하지 않음
  refund_policy text not null default 'revoke_access'
    check (refund_policy in ('revoke_access', 'revoke_unredeemed', 'none')),
  -- 알림톡 #{appDownloadUrl}에 넣을 앱 받는 곳. 앱 스토어 등록 전이라 설정값으로 둔다.
  app_download_url text check (app_download_url is null or app_download_url ~ '^https://'),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

insert into public.ilseong_app_settings (id) values (1) on conflict (id) do nothing;

comment on table public.ilseong_app_settings is
  '일성월심 앱 패키지 판매·환불 설정(한 줄). service_role 전용 — admin-web 서버가 읽고 쓴다.';

alter table public.ilseong_app_settings enable row level security;
revoke all on table public.ilseong_app_settings from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 앱 패키지 상품 표시
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.ilseong_app_products (
  product_id bigint primary key references public.products(id) on delete cascade,
  app_product_code text not null default 'ILSEONG_2028_SET4'
    check (app_product_code ~ '^[A-Za-z0-9_.:-]{1,64}$'),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

comment on table public.ilseong_app_products is
  '일성월심 앱 패키지 상품. 결제 확인 시 주문 줄마다 앱 코드를 발급한다. 상품 페이지 안내 표시용으로 공개 읽기, 쓰기는 관리자 RPC만.';

alter table public.ilseong_app_products enable row level security;
revoke all on table public.ilseong_app_products from anon, authenticated;
drop policy if exists ilseong_app_products_select_public on public.ilseong_app_products;
create policy ilseong_app_products_select_public on public.ilseong_app_products
  for select to anon, authenticated using (true);
grant select on table public.ilseong_app_products to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 주문 줄별 앱 코드 (패키지 1개 = 줄 1개 = 코드 1개)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.order_app_codes (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  order_item_id bigint not null references public.order_items(id) on delete cascade,
  unit_index integer not null check (unit_index >= 1),
  -- 앱 서버 lineRef: "주문상품id-순번"
  line_ref text not null unique check (line_ref ~ '^[A-Za-z0-9_.:-]{1,64}$'),
  app_product_code text not null,
  -- 앱 서버가 준 코드 원문. 주문자 본인과 서버만 읽는다.
  code text,
  -- 앱 서버 상태를 소문자로 비춘 값. pending = 아직 발급 전
  status text not null default 'pending' check (status in ('pending', 'issued', 'redeemed', 'revoked')),
  issued_at timestamptz,
  redeemed_at timestamptz,
  reissued_at timestamptz,
  notified_at timestamptz,
  -- 환불로 폐기 요청된 시각과 그때의 정책(revokeAccess). 처리되면 revoke_processed_at.
  revoke_requested_at timestamptz,
  revoke_access boolean,
  revoke_processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_item_id, unit_index)
);

create index if not exists order_app_codes_order_id_idx on public.order_app_codes(order_id);

comment on table public.order_app_codes is
  '일성월심 앱 코드(주문 줄별). code 원문은 주문 회원 본인(RLS)·비회원 인증 RPC·service_role만 읽는다.';

alter table public.order_app_codes enable row level security;
revoke all on table public.order_app_codes from anon, authenticated;
drop policy if exists order_app_codes_select_own on public.order_app_codes;
create policy order_app_codes_select_own on public.order_app_codes
  for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_app_codes.order_id
      and o.user_id is not null
      and o.user_id = auth.uid()
  ));
grant select on table public.order_app_codes to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 주문 단위 처리 대기열 (발급·폐기·알림을 상태로 맞춘다, 실패 시 간격을 늘려 재시도)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.ilseong_app_jobs (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'done', 'failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  done_at timestamptz
);

-- 주문마다 열린(pending) 작업은 하나
create unique index if not exists ilseong_app_jobs_open_order_uidx
  on public.ilseong_app_jobs(order_id) where status = 'pending';
create index if not exists ilseong_app_jobs_due_idx
  on public.ilseong_app_jobs(next_attempt_at) where status = 'pending';

comment on table public.ilseong_app_jobs is
  '일성월심 앱 코드 처리 대기열(주문 단위). admin-web 크론이 service_role RPC로 가져가 처리한다.';

alter table public.ilseong_app_jobs enable row level security;
revoke all on table public.ilseong_app_jobs from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. 내부 도우미
-- ─────────────────────────────────────────────────────────────────────────────
-- 주문에 남은 일이 있는가: 발급 전, 폐기 요청 미처리, 알림 미발송
create or replace function public._ilseong_app_order_outstanding(p_order_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.order_app_codes c
    where c.order_id = p_order_id
      and (
        (c.status = 'pending' and c.revoke_requested_at is null)
        or (c.revoke_requested_at is not null and c.revoke_processed_at is null)
        or (c.code is not null and c.status in ('issued', 'redeemed')
            and c.notified_at is null and c.revoke_requested_at is null)
      )
  );
$$;

-- 주문 작업을 지금 처리하도록 깨운다(열린 작업이 있으면 앞당기고, 없으면 새로 만든다)
create or replace function public._ilseong_app_touch_job(p_order_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ilseong_app_jobs (order_id)
  values (p_order_id)
  on conflict (order_id) where status = 'pending'
  do update set next_attempt_at = now(), attempts = 0, last_error = null, updated_at = now();
end;
$$;

-- 결제 확인된 주문의 앱 패키지 줄을 만들고 작업을 깨운다
create or replace function public._ilseong_app_enqueue_issue(p_order_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.order_app_codes (order_id, order_item_id, unit_index, line_ref, app_product_code)
  select oi.order_id, oi.id, g.n, oi.id::text || '-' || g.n::text, ap.app_product_code
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  left join public.books b on b.id = oi.book_id
  join public.ilseong_app_products ap on ap.product_id = coalesce(oi.product_id, b.product_id)
  cross join lateral generate_series(1, greatest(coalesce(oi.quantity, 1), 1)) as g(n)
  where oi.order_id = p_order_id
    and oi.refunded_at is null
    and o.payment_status = 'paid'
    and o.status not in ('cancelled', 'refunded')
  on conflict (order_item_id, unit_index) do nothing;

  get diagnostics v_count = row_count;

  if public._ilseong_app_order_outstanding(p_order_id) then
    perform public._ilseong_app_touch_job(p_order_id);
  end if;
  return v_count;
end;
$$;

-- 환불: 줄에 폐기 요청을 적는다. p_item_ids가 null이면 주문 전체.
create or replace function public._ilseong_app_request_revoke(p_order_id bigint, p_item_ids bigint[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_policy text;
  v_count integer;
begin
  select refund_policy into v_policy from public.ilseong_app_settings where id = 1;
  v_policy := coalesce(v_policy, 'revoke_access');
  if v_policy = 'none' then
    return 0;
  end if;

  update public.order_app_codes c
  set revoke_requested_at = now(),
      revoke_access = (v_policy = 'revoke_access'),
      updated_at = now()
  where c.order_id = p_order_id
    and (p_item_ids is null or c.order_item_id = any(p_item_ids))
    and c.revoke_requested_at is null;

  get diagnostics v_count = row_count;
  if v_count > 0 then
    perform public._ilseong_app_touch_job(p_order_id);
  end if;
  return v_count;
end;
$$;

revoke all on function public._ilseong_app_order_outstanding(bigint) from public, anon, authenticated;
revoke all on function public._ilseong_app_touch_job(bigint) from public, anon, authenticated;
revoke all on function public._ilseong_app_enqueue_issue(bigint) from public, anon, authenticated;
revoke all on function public._ilseong_app_request_revoke(bigint, bigint[]) from public, anon, authenticated;
grant execute on function public._ilseong_app_order_outstanding(bigint) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. 트리거 — 실패해도 결제·환불은 그대로 끝난다
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ilseong_app_on_order_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public._ilseong_app_enqueue_issue(new.id);
  exception when others then
    raise warning 'ilseong app enqueue failed (order %): %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create or replace function public.ilseong_app_on_order_closed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public._ilseong_app_request_revoke(new.id, null);
  exception when others then
    raise warning 'ilseong app revoke request failed (order %): %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create or replace function public.ilseong_app_on_item_refunded()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public._ilseong_app_request_revoke(new.order_id, array[new.id]);
  exception when others then
    raise warning 'ilseong app revoke request failed (order item %): %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

-- 환불 복원(refunded_at → null): 아직 앱 서버에 보내지 않은 폐기 요청만 거둔다.
-- 이미 폐기한 코드는 되살릴 수 없다(앱 서버 REVOKED는 끝 상태).
create or replace function public.ilseong_app_on_item_unrefunded()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    update public.order_app_codes
    set revoke_requested_at = null, revoke_access = null, updated_at = now()
    where order_item_id = new.id
      and revoke_requested_at is not null
      and revoke_processed_at is null;
  exception when others then
    raise warning 'ilseong app revoke cancel failed (order item %): %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

revoke all on function public.ilseong_app_on_order_paid() from public, anon, authenticated;
revoke all on function public.ilseong_app_on_order_closed() from public, anon, authenticated;
revoke all on function public.ilseong_app_on_item_refunded() from public, anon, authenticated;
revoke all on function public.ilseong_app_on_item_unrefunded() from public, anon, authenticated;

drop trigger if exists trg_orders_ilseong_app_paid on public.orders;
create trigger trg_orders_ilseong_app_paid
  after update of payment_status on public.orders
  for each row
  when (old.payment_status is distinct from new.payment_status and new.payment_status = 'paid')
  execute function public.ilseong_app_on_order_paid();

drop trigger if exists trg_orders_ilseong_app_closed on public.orders;
create trigger trg_orders_ilseong_app_closed
  after update of status on public.orders
  for each row
  when (old.status is distinct from new.status and new.status in ('cancelled', 'refunded'))
  execute function public.ilseong_app_on_order_closed();

drop trigger if exists trg_order_items_ilseong_app_refunded on public.order_items;
create trigger trg_order_items_ilseong_app_refunded
  after update of refunded_at on public.order_items
  for each row
  when (old.refunded_at is null and new.refunded_at is not null)
  execute function public.ilseong_app_on_item_refunded();

drop trigger if exists trg_order_items_ilseong_app_unrefunded on public.order_items;
create trigger trg_order_items_ilseong_app_unrefunded
  after update of refunded_at on public.order_items
  for each row
  when (old.refunded_at is not null and new.refunded_at is null)
  execute function public.ilseong_app_on_item_unrefunded();

-- 판매가 꺼져 있으면 앱 패키지 상품을 공개하지 못한다.
-- 이름이 products_enforce_derived_status_trigger보다 앞서 정렬돼 먼저 실행된다.
create or replace function public.ilseong_app_guard_product_listing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.ilseong_app_products where product_id = new.id)
     and not coalesce((select sales_enabled from public.ilseong_app_settings where id = 1), false) then
    raise exception '일성월심 앱 패키지 판매가 꺼져 있어 이 상품을 공개할 수 없습니다. 어드민 > 일성월심 앱에서 판매를 켠 뒤 공개해 주세요.';
  end if;
  return new;
end;
$$;

revoke all on function public.ilseong_app_guard_product_listing() from public, anon, authenticated;

drop trigger if exists products_app_package_sales_gate_trigger on public.products;
create trigger products_app_package_sales_gate_trigger
  before update of is_listed on public.products
  for each row
  when (new.is_listed is true and old.is_listed is not true)
  execute function public.ilseong_app_guard_product_listing();

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. 관리자 RPC — 상품을 앱 패키지로 지정/해제
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_get_ilseong_app_product(p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_row public.ilseong_app_products%rowtype;
  v_sales boolean;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  select * into v_row from public.ilseong_app_products where product_id = p_product_id;
  select sales_enabled into v_sales from public.ilseong_app_settings where id = 1;
  return jsonb_build_object(
    'product_id', p_product_id,
    'is_app_package', v_row.product_id is not null,
    'app_product_code', v_row.app_product_code,
    'sales_enabled', coalesce(v_sales, false)
  );
end;
$$;

create or replace function public.admin_set_ilseong_app_product(
  p_product_id bigint,
  p_is_app_package boolean,
  p_app_product_code text default 'ILSEONG_2028_SET4'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := btrim(coalesce(p_app_product_code, 'ILSEONG_2028_SET4'));
  v_sales boolean;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  if coalesce(p_is_app_package, false) then
    if v_code !~ '^[A-Za-z0-9_.:-]{1,64}$' then
      raise exception '앱 상품 코드 형식이 올바르지 않습니다.';
    end if;
    -- 앱 패키지는 수북 자체 판매 상품이다(위치·일련번호·상세 사진 점검 제외)
    insert into public.direct_sale_products (product_id) values (p_product_id)
    on conflict (product_id) do nothing;
    insert into public.ilseong_app_products (product_id, app_product_code)
    values (p_product_id, v_code)
    on conflict (product_id) do update set app_product_code = excluded.app_product_code;

    -- 판매가 꺼져 있으면 지정과 동시에 숨긴다(이미 결제된 주문의 코드 발급과는 무관)
    select sales_enabled into v_sales from public.ilseong_app_settings where id = 1;
    if not coalesce(v_sales, false) then
      update public.products set is_listed = false where id = p_product_id and is_listed;
    end if;
  else
    delete from public.ilseong_app_products where product_id = p_product_id;
  end if;

  return public.admin_get_ilseong_app_product(p_product_id);
end;
$$;

revoke all on function public.admin_get_ilseong_app_product(bigint) from public, anon;
revoke all on function public.admin_set_ilseong_app_product(bigint, boolean, text) from public, anon;
grant execute on function public.admin_get_ilseong_app_product(bigint) to authenticated, service_role;
grant execute on function public.admin_set_ilseong_app_product(bigint, boolean, text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. 서버(service_role) RPC — admin-web 크론·관리 API 전용
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ilseong_app_get_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'sales_enabled', s.sales_enabled,
    'refund_policy', s.refund_policy,
    'app_download_url', s.app_download_url,
    'updated_at', s.updated_at
  )
  from public.ilseong_app_settings s where s.id = 1;
$$;

-- 판매 켜기는 서버가 앱 서버 연결 설정을 확인한 뒤에만 부른다.
-- 판매를 끄면 앱 패키지 상품을 모두 숨긴다.
create or replace function public.ilseong_app_save_settings(
  p_sales_enabled boolean,
  p_refund_policy text,
  p_app_download_url text,
  p_actor uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := nullif(btrim(coalesce(p_app_download_url, '')), '');
begin
  if p_refund_policy is not null and p_refund_policy not in ('revoke_access', 'revoke_unredeemed', 'none') then
    raise exception '환불 처리 방식이 올바르지 않습니다.';
  end if;
  if v_url is not null and v_url !~ '^https://' then
    raise exception '앱 받는 곳 주소는 https://로 시작해야 합니다.';
  end if;

  update public.ilseong_app_settings
  set sales_enabled = coalesce(p_sales_enabled, sales_enabled),
      refund_policy = coalesce(p_refund_policy, refund_policy),
      app_download_url = v_url,
      updated_at = now(),
      updated_by = p_actor
  where id = 1;

  if p_sales_enabled is false then
    update public.products p set is_listed = false
    where p.is_listed and exists (select 1 from public.ilseong_app_products ap where ap.product_id = p.id);
  end if;

  return public.ilseong_app_get_settings();
end;
$$;

-- 연결 설정이 없을 때 크론이 부른다: 켜져 있던 판매를 끈다(없으면 아무 일 없음).
create or replace function public.ilseong_app_disable_sales()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.ilseong_app_settings where id = 1 and sales_enabled) then
    perform public.ilseong_app_save_settings(false, null,
      (select app_download_url from public.ilseong_app_settings where id = 1), null);
    return true;
  end if;
  return false;
end;
$$;

-- 처리할 작업 하나를 가져간다(동시 실행 대비 skip locked + 잠금 시각)
create or replace function public.ilseong_app_claim_job()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.ilseong_app_jobs%rowtype;
begin
  select * into v_job
  from public.ilseong_app_jobs j
  where j.status = 'pending'
    and j.next_attempt_at <= now()
    and (j.locked_until is null or j.locked_until < now())
  order by j.next_attempt_at, j.id
  limit 1
  for update skip locked;

  if not found then
    return null;
  end if;

  update public.ilseong_app_jobs
  set attempts = attempts + 1, locked_until = now() + interval '2 minutes', updated_at = now()
  where id = v_job.id
  returning * into v_job;

  return jsonb_build_object('id', v_job.id, 'order_id', v_job.order_id, 'attempts', v_job.attempts);
end;
$$;

-- 주문 처리에 필요한 정보(코드 원문 포함 — service_role 전용)
create or replace function public.ilseong_app_order_context(p_order_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id,
      'order_number', o.order_number,
      'user_id', o.user_id,
      'status', o.status,
      'payment_status', o.payment_status,
      'recipient_name', o.shipping_recipient_name,
      'recipient_phone', o.shipping_recipient_phone
    ),
    'settings', public.ilseong_app_get_settings(),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'order_item_id', c.order_item_id,
        'line_ref', c.line_ref,
        'app_product_code', c.app_product_code,
        'title', oi.title,
        'code', c.code,
        'status', c.status,
        'issued_at', c.issued_at,
        'redeemed_at', c.redeemed_at,
        'reissued_at', c.reissued_at,
        'notified_at', c.notified_at,
        'revoke_requested_at', c.revoke_requested_at,
        'revoke_access', c.revoke_access,
        'revoke_processed_at', c.revoke_processed_at
      ) order by c.id)
      from public.order_app_codes c
      join public.order_items oi on oi.id = c.order_item_id
      where c.order_id = o.id
    ), '[]'::jsonb)
  )
  from public.orders o
  where o.id = p_order_id;
$$;

-- 앱 서버 응답을 줄에 기록한다. p_lines: [{lineRef, code, status, issuedAt, redeemedAt}]
-- p_reissued=true면 바뀐 코드에 reissued_at을 찍고 알림 기록을 비운다(새 코드 안내 필요).
create or replace function public.ilseong_app_record_lines(p_order_id bigint, p_lines jsonb, p_reissued boolean default false)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line jsonb;
  v_status text;
  v_code text;
  v_count integer := 0;
begin
  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_status := lower(coalesce(v_line->>'status', ''));
    if v_status not in ('issued', 'redeemed', 'revoked') then
      continue;
    end if;
    v_code := nullif(btrim(coalesce(v_line->>'code', '')), '');

    update public.order_app_codes c
    set code = coalesce(v_code, c.code),
        status = v_status,
        issued_at = coalesce(nullif(v_line->>'issuedAt', '')::timestamptz, c.issued_at),
        redeemed_at = coalesce(nullif(v_line->>'redeemedAt', '')::timestamptz, c.redeemed_at),
        reissued_at = case when p_reissued and v_code is distinct from c.code then now() else c.reissued_at end,
        notified_at = case when p_reissued and v_code is distinct from c.code then null else c.notified_at end,
        revoke_processed_at = case
          when v_status = 'revoked' and c.revoke_requested_at is not null then coalesce(c.revoke_processed_at, now())
          else c.revoke_processed_at
        end,
        updated_at = now()
    where c.order_id = p_order_id
      and c.line_ref = v_line->>'lineRef';
    if found then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

-- 폐기 요청을 앱 서버에 보낸 줄(또는 앱 서버에 없는 줄)을 처리 완료로 적는다
create or replace function public.ilseong_app_mark_revoke_processed(p_order_id bigint, p_line_refs text[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.order_app_codes
  set revoke_processed_at = coalesce(revoke_processed_at, now()),
      -- 앱 서버에 없던(발급 전) 줄은 폐기로 본다
      status = case when status = 'pending' then 'revoked' else status end,
      updated_at = now()
  where order_id = p_order_id
    and line_ref = any(coalesce(p_line_refs, array[]::text[]))
    and revoke_requested_at is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.ilseong_app_mark_notified(p_order_id bigint, p_line_refs text[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.order_app_codes
  set notified_at = now(), updated_at = now()
  where order_id = p_order_id
    and line_ref = any(coalesce(p_line_refs, array[]::text[]));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 작업 마치기. 오류면 1·2·4…분 간격(최대 6시간)으로 다시, 12회 넘으면 실패 처리 + 운영 경보.
create or replace function public.ilseong_app_finish_job(p_job_id bigint, p_error text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.ilseong_app_jobs%rowtype;
  v_order_number text;
  v_delay interval;
  c_max_attempts constant integer := 12;
begin
  select * into v_job from public.ilseong_app_jobs where id = p_job_id for update;
  if not found then
    return null;
  end if;

  if p_error is null then
    if public._ilseong_app_order_outstanding(v_job.order_id) then
      -- 처리 중 새 일이 생겼다(예: 환불). 곧 다시 처리한다.
      if v_job.attempts >= c_max_attempts then
        p_error := '처리 후에도 남은 작업이 계속 있습니다.';
      else
        update public.ilseong_app_jobs
        set next_attempt_at = now(), locked_until = null, last_error = null, updated_at = now()
        where id = p_job_id
        returning * into v_job;
        return jsonb_build_object('id', v_job.id, 'status', v_job.status, 'again', true);
      end if;
    else
      update public.ilseong_app_jobs
      set status = 'done', done_at = now(), locked_until = null, last_error = null, updated_at = now()
      where id = p_job_id
      returning * into v_job;
      return jsonb_build_object('id', v_job.id, 'status', v_job.status);
    end if;
  end if;

  if v_job.attempts >= c_max_attempts then
    update public.ilseong_app_jobs
    set status = 'failed', locked_until = null, last_error = left(p_error, 1000), updated_at = now()
    where id = p_job_id
    returning * into v_job;

    select order_number into v_order_number from public.orders where id = v_job.order_id;
    perform public.notify_ops_slack(format(
      ':rotating_light: 일성월심 앱 코드 처리 %s회 실패 — 주문 %s%s오류: %s%s어드민 > 일성월심 앱에서 다시 시도해 주세요.',
      v_job.attempts, coalesce(v_order_number, v_job.order_id::text), E'\n', left(p_error, 300), E'\n'));
  else
    v_delay := make_interval(mins => least(360, power(2, greatest(v_job.attempts, 1) - 1)::integer));
    update public.ilseong_app_jobs
    set next_attempt_at = now() + v_delay, locked_until = null, last_error = left(p_error, 1000), updated_at = now()
    where id = p_job_id
    returning * into v_job;
  end if;

  return jsonb_build_object('id', v_job.id, 'status', v_job.status, 'next_attempt_at', v_job.next_attempt_at,
    'attempts', v_job.attempts);
end;
$$;

-- 관리 화면: 다시 시도(실패·대기 작업을 지금 처리)
create or replace function public.ilseong_app_retry_order(p_order_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.order_app_codes where order_id = p_order_id) then
    return false;
  end if;
  update public.ilseong_app_jobs set status = 'done', done_at = now(), updated_at = now()
  where order_id = p_order_id and status = 'failed';
  perform public._ilseong_app_touch_job(p_order_id);
  return true;
end;
$$;

-- 관리 화면 요약: 작업 상태별 수, 처리 중·실패 작업, 앱 패키지 상품
create or replace function public.ilseong_app_admin_overview()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'settings', public.ilseong_app_get_settings(),
    'counts', jsonb_build_object(
      'pending', (select count(*) from public.ilseong_app_jobs where status = 'pending'),
      'failed', (select count(*) from public.ilseong_app_jobs where status = 'failed'),
      'lines_pending', (select count(*) from public.order_app_codes where status = 'pending' and revoke_requested_at is null),
      'lines_issued', (select count(*) from public.order_app_codes where status = 'issued'),
      'lines_redeemed', (select count(*) from public.order_app_codes where status = 'redeemed'),
      'lines_revoked', (select count(*) from public.order_app_codes where status = 'revoked')
    ),
    'jobs', coalesce((
      select jsonb_agg(x order by x->>'status' desc, (x->>'next_attempt_at'))
      from (
        select jsonb_build_object(
          'id', j.id, 'order_id', j.order_id, 'order_number', o.order_number, 'status', j.status,
          'attempts', j.attempts, 'next_attempt_at', j.next_attempt_at, 'last_error', j.last_error,
          'updated_at', j.updated_at
        ) as x
        from public.ilseong_app_jobs j
        join public.orders o on o.id = j.order_id
        where j.status in ('pending', 'failed')
        order by j.updated_at desc
        limit 50
      ) t
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_id', p.id, 'title', p.title, 'option', p.option, 'status', p.status,
        'is_listed', p.is_listed, 'app_product_code', ap.app_product_code
      ) order by p.id)
      from public.ilseong_app_products ap
      join public.products p on p.id = ap.product_id
    ), '[]'::jsonb)
  );
$$;

create or replace function public.ilseong_app_find_order(p_order_number text)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select o.id from public.orders o
  where upper(o.order_number) = upper(btrim(coalesce(p_order_number, '')))
  limit 1;
$$;

do $$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.ilseong_app_get_settings()',
    'public.ilseong_app_save_settings(boolean, text, text, uuid)',
    'public.ilseong_app_disable_sales()',
    'public.ilseong_app_claim_job()',
    'public.ilseong_app_order_context(bigint)',
    'public.ilseong_app_record_lines(bigint, jsonb, boolean)',
    'public.ilseong_app_mark_revoke_processed(bigint, text[])',
    'public.ilseong_app_mark_notified(bigint, text[])',
    'public.ilseong_app_finish_job(bigint, text)',
    'public.ilseong_app_retry_order(bigint)',
    'public.ilseong_app_admin_overview()',
    'public.ilseong_app_find_order(text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
    execute format('grant execute on function %s to service_role', v_fn);
  end loop;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. 구매자 RPC — 회원 본인 / 비회원 주문 조회 인증
-- ─────────────────────────────────────────────────────────────────────────────
-- 화면용 줄 모양. 환불로 끝난 코드와 발급 전 코드는 원문을 내보내지 않는다.
create or replace function public._ilseong_app_buyer_lines(p_order_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'line_ref', c.line_ref,
    'order_item_id', c.order_item_id,
    'unit_index', c.unit_index,
    'title', oi.title,
    'state', case
      when c.revoke_requested_at is not null or c.status = 'revoked' then 'ended'
      when c.status = 'redeemed' then 'redeemed'
      when c.status = 'issued' and c.code is not null then 'issued'
      else 'pending'
    end,
    'code', case
      when c.revoke_requested_at is null and c.status in ('issued', 'redeemed') then c.code
      else null
    end,
    'issued_at', c.issued_at,
    'redeemed_at', c.redeemed_at
  ) order by c.order_item_id, c.unit_index), '[]'::jsonb)
  from public.order_app_codes c
  join public.order_items oi on oi.id = c.order_item_id
  where c.order_id = p_order_id;
$$;

revoke all on function public._ilseong_app_buyer_lines(bigint) from public, anon, authenticated;

create or replace function public.get_my_order_app_codes(p_order_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return '[]'::jsonb;
  end if;
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.user_id = v_uid) then
    return '[]'::jsonb;
  end if;
  return public._ilseong_app_buyer_lines(p_order_id);
end;
$$;

revoke all on function public.get_my_order_app_codes(bigint) from public, anon;
grant execute on function public.get_my_order_app_codes(bigint) to authenticated, service_role;

-- get_guest_order와 같은 인증(비회원 주문 + 주문번호 + 휴대폰)과 실패 횟수 제한
create or replace function public.get_guest_order_app_codes(p_order_number text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip text;
  v_fail_count integer;
  v_order_number text;
  v_phone_digits text;
  v_order_id bigint;
begin
  begin
    v_ip := split_part(coalesce(
      current_setting('request.headers', true)::jsonb->>'x-forwarded-for', ''
    ), ',', 1);
  exception when others then
    v_ip := '';
  end;
  if v_ip is null or btrim(v_ip) = '' then
    v_ip := 'noip';
  end if;

  select count(*) into v_fail_count
  from public.guest_order_lookup_attempts a
  where a.bucket_key = v_ip
    and a.attempted_at > now() - interval '15 minutes';
  if v_fail_count >= 20 then
    raise exception '조회 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.';
  end if;

  v_order_number := upper(btrim(coalesce(p_order_number, '')));
  v_phone_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');

  select o.id into v_order_id
  from public.orders o
  where o.user_id is null
    and upper(o.order_number) = v_order_number
    and regexp_replace(coalesce(o.shipping_recipient_phone, ''), '\D', '', 'g') = v_phone_digits
    and length(v_phone_digits) >= 9;

  if v_order_id is null then
    insert into public.guest_order_lookup_attempts (bucket_key) values (v_ip);
    return jsonb_build_object('found', false, 'lines', '[]'::jsonb);
  end if;

  return jsonb_build_object('found', true, 'lines', public._ilseong_app_buyer_lines(v_order_id));
end;
$$;

revoke all on function public.get_guest_order_app_codes(text, text) from public;
grant execute on function public.get_guest_order_app_codes(text, text) to anon, authenticated, service_role;

commit;
