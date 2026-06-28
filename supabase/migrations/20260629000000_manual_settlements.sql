-- 수동 정산(식스샵 구 사이트·오프라인 판매분) 추적 — Model C
-- ------------------------------------------------------------------------------------
-- 정책(2026-06-29): "판매완료"와 "정산완료(셀러 입금)"를 책 상태(books.status) 한 칸에
-- 욱여넣지 않는다. 책 상태는 재고 축으로 단일 유지(팔리면 settled로 내려감). 셀러 입금
-- 여부는 책이 아니라 '정산 레코드' 쪽에서 추적한다.
--
--  - 신규 플랫폼 주문 정산: 기존 settlements 테이블 + 트리거(create_settlements_for_order)가 담당.
--    (주문 NOT NULL, 회원 셀러 전제)
--  - 이 테이블(manual_settlements): 주문 없이(비회원·오프라인·식스샵 구 사이트) 팔린 책의
--    정산(입금) 추적 전용. 수수료/예상 정산액은 플랫폼 수수료 공식으로 계산해 참고용으로 저장하되,
--    "입금했는가"의 단일 진실은 status(unpaid/paid) 플래그다.
--
-- 함께 추가하는 운영자 수동 오버라이드 RPC:
--  - admin_commit_manual_settlement : 엑셀 매칭 결과를 받아 책 settled 플립 + manual_settlements 기록(멱등)
--  - admin_list_manual_settlements  : 수동 정산 목록/요약
--  - admin_set_manual_settlement_paid : 입금완료/대기 토글
--  - admin_revert_settled_books      : settled → on_sale 되돌리기(실수 정정)
--  - admin_run_order_settlement      : 플랫폼 주문 정산 생성을 수동 트리거(자동 트리거 누락 대비)

-- 1) 테이블 ---------------------------------------------------------------------------
create table if not exists public.manual_settlements (
  id            bigint generated always as identity primary key,
  book_id       bigint not null references public.books(id) on delete cascade,
  shipment_id   bigint references public.shipments(id) on delete set null,
  seller_name   text,
  seller_phone  text,
  source        text not null default 'sixshop',
  batch_label   text,
  sale_amount   integer not null default 0 check (sale_amount >= 0),
  fee_percent   numeric(5, 2) check (fee_percent is null or (fee_percent >= 0 and fee_percent <= 100)),
  fee_amount    integer check (fee_amount is null or fee_amount >= 0),
  net_amount    integer check (net_amount is null or net_amount >= 0),
  status        text not null default 'unpaid' check (status in ('unpaid', 'paid', 'cancelled')),
  paid_at       timestamptz,
  paid_by       uuid,
  sold_at       date,
  notes         text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (book_id)
);

create index if not exists manual_settlements_status_idx on public.manual_settlements (status);
create index if not exists manual_settlements_seller_idx on public.manual_settlements (seller_name);
create index if not exists manual_settlements_batch_idx on public.manual_settlements (batch_label);

alter table public.manual_settlements enable row level security;

drop policy if exists manual_settlements_admin_all on public.manual_settlements;
create policy manual_settlements_admin_all on public.manual_settlements
  for all
  using (public.is_admin_user())
  with check (public.is_admin_user());

create or replace function public.touch_manual_settlements_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists manual_settlements_set_updated_at on public.manual_settlements;
create trigger manual_settlements_set_updated_at
before update on public.manual_settlements
for each row
execute function public.touch_manual_settlements_updated_at();

-- 2) commit: 엑셀 매칭 결과 → 책 settled 플립 + manual_settlements 기록 (멱등) -----------
--    p_items: [{ "book_id": 123, "sale_amount": 5000, "batch_label": "2026-06-09" }, ...]
create or replace function public.admin_commit_manual_settlement(
  p_items jsonb,
  p_update_price boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item              jsonb;
  v_book_id           bigint;
  v_sale              integer;
  v_batch             text;
  v_book              record;
  v_fee_percent       numeric(5, 2);
  v_fee               integer;
  v_net               integer;
  v_existing_status   text;
  v_settled_count     integer := 0;
  v_already_settled   integer := 0;
  v_record_created    integer := 0;
  v_record_updated    integer := 0;
  v_price_updated     integer := 0;
  v_skipped_paid      integer := 0;
  v_skipped_discarded integer := 0;
  v_not_found         integer := 0;
  v_uid               uuid := auth.uid();
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_book_id := nullif(v_item->>'book_id', '')::bigint;
    v_sale := greatest(0, coalesce(nullif(v_item->>'sale_amount', '')::integer, 0));
    v_batch := nullif(v_item->>'batch_label', '');

    if v_book_id is null then
      continue;
    end if;

    select b.id, b.status, b.price, b.shipment_id,
           s.seller_name, s.seller_phone, s.pickup_date
      into v_book
      from public.books b
      left join public.shipments s on s.id = b.shipment_id
      where b.id = v_book_id;

    if not found then
      v_not_found := v_not_found + 1;
      continue;
    end if;

    if v_book.status = 'discarded' then
      v_skipped_discarded := v_skipped_discarded + 1;
      continue;
    end if;

    -- (선택) 판매가 갱신: 엑셀 실판매가로 books.price 정정
    if p_update_price and v_sale > 0 and v_book.price is distinct from v_sale then
      update public.books set price = v_sale where id = v_book_id;
      v_price_updated := v_price_updated + 1;
    end if;

    -- 예상 정산액(참고용): 플랫폼 수수료 공식. 식스샵 실제 정산액과 다를 수 있음.
    v_fee_percent := public.calculate_settlement_fee_percent(v_sale, coalesce(v_book.pickup_date, current_date));
    v_fee := floor(v_sale * (coalesce(v_fee_percent, 0) / 100))::integer;
    v_net := greatest(0, v_sale - v_fee);

    -- 책 상태 플립 (재고 축)
    if v_book.status = 'settled' then
      v_already_settled := v_already_settled + 1;
    elsif v_book.status in ('on_sale', 'reserved') then
      update public.books set status = 'settled' where id = v_book_id;
      v_settled_count := v_settled_count + 1;
    end if;

    -- 정산 레코드 upsert (입금완료 레코드는 금액 보존)
    select status into v_existing_status from public.manual_settlements where book_id = v_book_id;

    if not found then
      insert into public.manual_settlements (
        book_id, shipment_id, seller_name, seller_phone, source, batch_label,
        sale_amount, fee_percent, fee_amount, net_amount, status, created_by
      ) values (
        v_book_id, v_book.shipment_id, v_book.seller_name, v_book.seller_phone, 'sixshop', v_batch,
        v_sale, v_fee_percent, v_fee, v_net, 'unpaid', v_uid
      );
      v_record_created := v_record_created + 1;
    elsif v_existing_status = 'paid' then
      v_skipped_paid := v_skipped_paid + 1;
    else
      update public.manual_settlements set
        shipment_id  = v_book.shipment_id,
        seller_name  = v_book.seller_name,
        seller_phone = v_book.seller_phone,
        batch_label  = coalesce(v_batch, batch_label),
        sale_amount  = v_sale,
        fee_percent  = v_fee_percent,
        fee_amount   = v_fee,
        net_amount   = v_net,
        status       = 'unpaid'
      where book_id = v_book_id;
      v_record_updated := v_record_updated + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'settled_count', v_settled_count,
    'already_settled_count', v_already_settled,
    'record_created', v_record_created,
    'record_updated', v_record_updated,
    'price_updated_count', v_price_updated,
    'skipped_paid_count', v_skipped_paid,
    'skipped_discarded_count', v_skipped_discarded,
    'not_found_count', v_not_found
  );
end;
$$;

-- 3) list: 수동 정산 목록 + 요약 ------------------------------------------------------
create or replace function public.admin_list_manual_settlements(
  p_search text default null,
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows    jsonb;
  v_summary jsonb;
  v_total   bigint;
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  -- 요약(검색 필터만 적용, 상태 전체) — 카드에 항상 미지급/지급/전체 합계 노출
  select jsonb_build_object(
    'unpaid_count',  count(*) filter (where ms.status = 'unpaid'),
    'unpaid_amount', coalesce(sum(ms.net_amount) filter (where ms.status = 'unpaid'), 0),
    'paid_count',    count(*) filter (where ms.status = 'paid'),
    'paid_amount',   coalesce(sum(ms.net_amount) filter (where ms.status = 'paid'), 0),
    'all_count',     count(*),
    'all_amount',    coalesce(sum(ms.net_amount), 0)
  )
  into v_summary
  from public.manual_settlements ms
  join public.books b on b.id = ms.book_id
  where (p_search is null or p_search = ''
         or ms.seller_name ilike '%' || p_search || '%'
         or b.title ilike '%' || p_search || '%'
         or ms.seller_phone ilike '%' || p_search || '%');

  select count(*)
  into v_total
  from public.manual_settlements ms
  join public.books b on b.id = ms.book_id
  where (p_status is null or p_status = 'all' or ms.status = p_status)
    and (p_search is null or p_search = ''
         or ms.seller_name ilike '%' || p_search || '%'
         or b.title ilike '%' || p_search || '%'
         or ms.seller_phone ilike '%' || p_search || '%');

  select coalesce(jsonb_agg(to_jsonb(r) order by (r.status = 'unpaid') desc, r.seller_name, r.id), '[]'::jsonb)
  into v_rows
  from (
    select ms.id, ms.book_id, ms.seller_name, ms.seller_phone, ms.source, ms.batch_label,
           ms.sale_amount, ms.fee_percent, ms.fee_amount, ms.net_amount, ms.status,
           ms.paid_at, ms.sold_at, ms.notes, ms.created_at,
           b.title as book_title, b.option as book_option
    from public.manual_settlements ms
    join public.books b on b.id = ms.book_id
    where (p_status is null or p_status = 'all' or ms.status = p_status)
      and (p_search is null or p_search = ''
           or ms.seller_name ilike '%' || p_search || '%'
           or b.title ilike '%' || p_search || '%'
           or ms.seller_phone ilike '%' || p_search || '%')
    order by (ms.status = 'unpaid') desc, ms.seller_name, ms.id
    limit greatest(0, coalesce(p_limit, 100))
    offset greatest(0, coalesce(p_offset, 0))
  ) r;

  return jsonb_build_object('rows', v_rows, 'summary', v_summary, 'total_count', v_total);
end;
$$;

-- 4) 입금완료/대기 토글 ---------------------------------------------------------------
create or replace function public.admin_set_manual_settlement_paid(
  p_ids bigint[],
  p_paid boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_uid   uuid := auth.uid();
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  update public.manual_settlements
  set status  = case when p_paid then 'paid' else 'unpaid' end,
      paid_at = case when p_paid then now() else null end,
      paid_by = case when p_paid then v_uid else null end
  where id = any(p_ids)
    and status <> 'cancelled';

  get diagnostics v_count = row_count;
  return jsonb_build_object('updated_count', v_count);
end;
$$;

-- 5) settled → on_sale 되돌리기(실수 정정). 관련 정산 레코드는 cancelled 처리 -----------
--    (is_public은 건드리지 않음 — 필요 시 운영자가 카탈로그에서 재노출)
create or replace function public.admin_revert_settled_books(p_book_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_books integer;
  v_ms    integer;
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  update public.books set status = 'on_sale'
  where id = any(p_book_ids) and status = 'settled';
  get diagnostics v_books = row_count;

  update public.manual_settlements set status = 'cancelled'
  where book_id = any(p_book_ids) and status <> 'paid';
  get diagnostics v_ms = row_count;

  return jsonb_build_object('reverted_books', v_books, 'cancelled_records', v_ms);
end;
$$;

-- 6) 플랫폼 주문 정산 생성 수동 트리거(자동 트리거 누락 대비) ----------------------------
--    create_settlements_for_order는 service_role 전용 → admin SECURITY DEFINER 래퍼에서 호출.
create or replace function public.admin_run_order_settlement(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_user() then
    raise exception 'forbidden: admin only';
  end if;

  v_result := public.create_settlements_for_order(p_order_id);
  return jsonb_build_object('ok', true, 'order_id', p_order_id, 'result', v_result);
end;
$$;

grant execute on function public.admin_commit_manual_settlement(jsonb, boolean) to authenticated;
grant execute on function public.admin_list_manual_settlements(text, text, integer, integer) to authenticated;
grant execute on function public.admin_set_manual_settlement_paid(bigint[], boolean) to authenticated;
grant execute on function public.admin_revert_settled_books(bigint[]) to authenticated;
grant execute on function public.admin_run_order_settlement(bigint) to authenticated;
