-- 상품재고 탭: 상품별 상태 변경 이력 노출 (2026-08-01)
--
-- 배경: 운영자가 "이 상품이 언제 품절/판매중으로 바뀌었고, 관리자가 수동으로 바꾼 건지
--       주문·결제·만료 같은 시스템 흐름이 자동으로 바꾼 건지"를 화면에서 확인할 수 없었다.
--       권별(books) 변경은 book_change_logs 트리거가 2026-05-13부터 status/is_public/price/
--       condition_grade를 changed_by(auth.uid)와 함께 기록 중이지만 조회 UI·RPC가 없었고,
--       상품(파생 status: selling/sold_out/hidden) 전이는 아예 기록되지 않았다.
--
-- 구성 (전부 additive):
--   1) product_status_logs        — products.status(재고 파생값) 전이 기록 테이블 + 트리거.
--                                   본 배포 시점부터 축적된다 (과거 소급 불가 — 합성 백필 안 함).
--   2) admin_get_product_status_history — 상품 단위 통합 타임라인 조회 RPC.
--      상품 전이 + 권별 status/is_public 변경 + 권 등록(입고, books.created_at 합성)을
--      시간 역순으로 합치고, changed_by를 관리자/회원/시스템(null)으로 분류해 준다.
--
-- 행위자 분류 규칙:
--   changed_by null                          → 'system' (pg_cron 만료, service_role 서버리스 등)
--   changed_by 이메일이 admin_users에 존재    → 'admin'  (어드민 수동 조작)
--   그 외 authenticated 사용자               → 'member' (구매자 주문/취소 등 회원 행위로 인한 자동 전이)

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) product_status_logs — 상품 파생 상태 전이 기록
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.product_status_logs (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products(id) on delete cascade,
  changed_by uuid null references auth.users(id) on delete set null,
  old_status text null,
  new_status text not null,
  changed_at timestamptz not null default now()
);

comment on table public.product_status_logs is
  '상품 파생 상태(selling/sold_out/hidden) 전이 이력. changed_by null = 시스템 자동.';

create index if not exists idx_product_status_logs_product
  on public.product_status_logs (product_id, changed_at desc);

alter table public.product_status_logs enable row level security;

drop policy if exists product_status_logs_admin_select on public.product_status_logs;
create policy product_status_logs_admin_select
  on public.product_status_logs
  for select
  to authenticated
  using (public.is_admin_user());

-- INSERT 정책은 없음 — 아래 security definer 트리거 함수만 기록한다.

-- books_log_changes()와 같은 패턴: 컬럼 한정 AFTER UPDATE OF 대신 전체 UPDATE에서
-- distinct 검사 (BEFORE 트리거가 status를 고칠 때 OF 목록 판정에 안 걸리는 케이스 방지).
create or replace function public.products_log_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into public.product_status_logs (product_id, changed_by, old_status, new_status)
    values (new.id, auth.uid(), old.status, new.status);
  end if;
  return new;
end;
$$;

drop trigger if exists products_log_status_change_trigger on public.products;
create trigger products_log_status_change_trigger
  after update on public.products
  for each row
  execute function public.products_log_status_change();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) admin_get_product_status_history — 상품 단위 통합 이력 조회
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.admin_get_product_status_history(
  p_product_id bigint,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_events jsonb;
  v_limit integer;
begin
  if not public.is_admin_user() then
    raise exception 'Admin access required';
  end if;

  v_limit := greatest(1, least(coalesce(p_limit, 200), 500));

  with merged as (
    -- a) 상품(파생 상태) 전이 — 본 마이그레이션 배포 시점부터
    select
      psl.changed_at,
      'product_status'::text as kind,
      null::bigint as book_id,
      null::integer as serial_number,
      null::text as seller_name,
      psl.old_status as old_value,
      psl.new_status as new_value,
      psl.changed_by
    from public.product_status_logs psl
    where psl.product_id = p_product_id

    union all

    -- b) 권별 판매상태/노출 변경 — book_change_logs (2026-05-13부터 축적)
    select
      l.changed_at,
      case when l.field = 'status' then 'book_status' else 'book_visibility' end,
      b.id,
      b.serial_number,
      s.seller_name,
      l.old_value,
      l.new_value,
      l.changed_by
    from public.book_change_logs l
    join public.books b on b.id = l.book_id
    left join public.shipments s on s.id = b.shipment_id
    where b.product_id = p_product_id
      and l.field in ('status', 'is_public')

    union all

    -- c) 권 등록(입고) — books.created_at 합성 이벤트 (행위자 기록 없음 → actor null)
    select
      b.created_at,
      'book_registered',
      b.id,
      b.serial_number,
      s.seller_name,
      null,
      null,
      null::uuid
    from public.books b
    left join public.shipments s on s.id = b.shipment_id
    where b.product_id = p_product_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'changed_at', m.changed_at,
    'kind', m.kind,
    'book_id', m.book_id,
    'serial_number', m.serial_number,
    'seller_name', m.seller_name,
    'old_value', m.old_value,
    'new_value', m.new_value,
    'actor_type', case
      when m.kind = 'book_registered' then null
      when m.changed_by is null then 'system'
      when exists (
        select 1 from public.admin_users au
        where lower(au.email) = lower(coalesce(u.email, ''))
      ) then 'admin'
      else 'member'
    end,
    'actor_name', case
      when m.changed_by is null then null
      else coalesce(mp.name, nullif(split_part(coalesce(u.email, ''), '@', 1), ''))
    end
    -- 같은 트랜잭션이면 changed_at(now())이 동일 — 권 이벤트가 원인, 상품 전이가 결과이므로
    -- 최신순 목록에서 상품 전이를 위에 보이게 정렬한다.
  ) order by m.changed_at desc, case when m.kind = 'product_status' then 0 else 1 end asc), '[]'::jsonb)
  into v_events
  from (
    select *
    from merged
    order by changed_at desc, case when kind = 'product_status' then 0 else 1 end asc
    limit v_limit
  ) m
  left join auth.users u on u.id = m.changed_by
  left join public.member_profiles mp on mp.user_id = m.changed_by;

  return jsonb_build_object('events', v_events, 'limit', v_limit);
end;
$$;

grant execute on function public.admin_get_product_status_history(bigint, integer) to authenticated;

commit;
