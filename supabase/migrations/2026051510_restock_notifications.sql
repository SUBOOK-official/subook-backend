-- 재입고 알림 시스템 (P3 Sprint 2-4)
--
-- 1. restock_notifications 테이블: 회원이 품절 상품에 알림 구독
-- 2. RPC: subscribe_restock, unsubscribe_restock, list_my_restock_subscriptions,
--         admin_list_pending_restock_alerts(cron 전용)
-- 3. 발송 정책: 회원이 구독한 product에 on_sale + is_public인 책이 있으면 알림 대상
--               (cron이 매일 1회 list_pending + 발송 + mark_notified)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 테이블
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.restock_notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  notified_at timestamptz null,
  notified_book_id bigint null references public.books(id) on delete set null
);

-- 활성 구독(미발송) 중복 방지: (user_id, product_id) where notified_at is null
create unique index if not exists uniq_restock_active_subscription
  on public.restock_notifications (user_id, product_id)
  where notified_at is null;

create index if not exists idx_restock_pending_by_product
  on public.restock_notifications (product_id)
  where notified_at is null;

create index if not exists idx_restock_user_recent
  on public.restock_notifications (user_id, created_at desc);

alter table public.restock_notifications enable row level security;

drop policy if exists restock_select_own on public.restock_notifications;
create policy restock_select_own on public.restock_notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists restock_admin_all on public.restock_notifications;
create policy restock_admin_all on public.restock_notifications
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 구독 등록 (idempotent)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.subscribe_restock(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_id bigint;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  perform public.assert_member_not_blocked();

  -- product 존재 확인
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception '상품을 찾을 수 없습니다.';
  end if;

  insert into public.restock_notifications (user_id, product_id)
  values (v_user_id, p_product_id)
  on conflict (user_id, product_id) where notified_at is null
  do nothing
  returning id into v_id;

  return jsonb_build_object('success', true, 'product_id', p_product_id);
end;
$$;

grant execute on function public.subscribe_restock(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 구독 취소
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.unsubscribe_restock(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_deleted_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  delete from public.restock_notifications
  where user_id = v_user_id
    and product_id = p_product_id
    and notified_at is null;

  get diagnostics v_deleted_count = row_count;

  return jsonb_build_object('success', true, 'product_id', p_product_id, 'deleted', v_deleted_count);
end;
$$;

grant execute on function public.unsubscribe_restock(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 내 활성 구독 목록 (마이페이지용)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.list_my_restock_subscriptions()
returns table (
  id bigint,
  product_id bigint,
  product_title text,
  product_subject text,
  product_brand text,
  product_cover_image_url text,
  is_available boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    rn.id,
    rn.product_id,
    p.title as product_title,
    p.subject as product_subject,
    p.brand as product_brand,
    p.cover_image_url as product_cover_image_url,
    exists (
      select 1 from public.books b
      where b.product_id = rn.product_id
        and b.status = 'on_sale'
        and b.is_public = true
    ) as is_available,
    rn.created_at
  from public.restock_notifications rn
  inner join public.products p on p.id = rn.product_id
  where rn.user_id = auth.uid()
    and rn.notified_at is null
  order by rn.created_at desc;
$$;

grant execute on function public.list_my_restock_subscriptions() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC: 내 특정 product 구독 여부 (상품 상세 페이지용)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.is_subscribed_restock(p_product_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.restock_notifications
    where user_id = auth.uid()
      and product_id = p_product_id
      and notified_at is null
  );
$$;

grant execute on function public.is_subscribed_restock(bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 어드민/cron 전용: 발송 대기 알림 목록 + mark
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_list_pending_restock_alerts(
  p_limit integer default 200
)
returns table (
  notification_id bigint,
  user_id uuid,
  user_email text,
  user_phone text,
  user_name text,
  product_id bigint,
  product_title text,
  available_book_id bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    rn.id as notification_id,
    rn.user_id,
    mp.email,
    mp.phone,
    mp.name,
    rn.product_id,
    p.title,
    (select b.id from public.books b
      where b.product_id = rn.product_id
        and b.status = 'on_sale'
        and b.is_public = true
      order by b.id limit 1) as available_book_id
  from public.restock_notifications rn
  inner join public.products p on p.id = rn.product_id
  left join public.member_profiles mp on mp.user_id = rn.user_id
  where rn.notified_at is null
    and exists (
      select 1 from public.books b
      where b.product_id = rn.product_id
        and b.status = 'on_sale'
        and b.is_public = true
    )
  order by rn.created_at
  limit greatest(p_limit, 1);
$$;

revoke execute on function public.admin_list_pending_restock_alerts(integer) from public;
revoke execute on function public.admin_list_pending_restock_alerts(integer) from authenticated;
grant execute on function public.admin_list_pending_restock_alerts(integer) to service_role;

create or replace function public.admin_mark_restock_notified(
  p_ids bigint[],
  p_notified_book_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.restock_notifications
  set notified_at = now(),
      notified_book_id = p_notified_book_id
  where id = any(p_ids)
    and notified_at is null;

  get diagnostics v_count = row_count;

  return jsonb_build_object('success', true, 'marked', v_count);
end;
$$;

revoke execute on function public.admin_mark_restock_notified(bigint[], bigint) from public;
revoke execute on function public.admin_mark_restock_notified(bigint[], bigint) from authenticated;
grant execute on function public.admin_mark_restock_notified(bigint[], bigint) to service_role;

commit;
