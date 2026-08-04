-- 구글시트 동기화 유실 수리 — 아웃박스 + 재시도 스윕 + 재전송 헬퍼
--
-- 사고(2026-08-03): ORD-2608-0069 / 0072 / 0073 판매내역 탭 미기록.
--   원인: Apps Script doPost의 lock.waitLock(20000)이 try/catch "바깥"에 있어
--   락 대기 20초 초과 시 예외 → 행 유실. 시트가 무거워져 쓰기 1건이 25초+
--   (다품목 주문은 수 분) 락을 점유하면서,
--     - 14:00:49 ORD-2608-0072가 직전(13:55) 10품목 주문 쓰기와 겹쳐 유실
--     - 14:20:06 일괄 입금확인 동시 3건(0067/0069/0073) 중 락을 못 잡은 2건 유실
--   DB 쪽은 fire-and-forget(pg_net 1회 발사, 응답 6h TTL)이라 재시도 수단이 없었다.
--
-- 수리 구조 (3단):
--   1) Apps Script v2(backend/docs/gsheet-sync-appsscript.gs — 별도 재배포 필요):
--      락을 try 안으로 + tryLock 240s, N행 블록 일괄쓰기(락 점유 수초로 단축),
--      주문번호/일련번호 멱등성(재전송 중복 방지), kind='ping' 응답.
--   2) 이 마이그레이션: gsheet_sync_outbox에 페이로드를 남기고 발사 →
--      pg_cron 스윕(5분)이 net._http_response로 성공("ok":true)을 확인,
--      실패·타임아웃·응답유실은 재전송(최대 10회, 회당 2건 직렬화).
--      ⚠ 재전송은 v2 스크립트의 멱등성이 전제 — ping이 확인되기 전에는
--      재전송하지 않는다(구버전 스크립트에 재전송하면 중복 행 생성).
--   3) admin_gsheet_resend_order(주문번호): 누락분 수동 재기록 시딩.
--
-- 기존 계약 유지:
--   - Vault 시크릿(gsheet_sync_webhook_url/token) 없으면 전부 no-op
--     (대량 books INSERT 전 URL 삭제해 시트 유입 차단하는 운영 관행 그대로).
--   - 트리거 실패가 결제 확인/재고 등록 본 흐름을 막지 않는다(예외 전부 삼킴).
--   - 트리거 발화 조건 불변: orders UPDATE pending→paid|preparing, books INSERT on_sale.

begin;

-- ── 1) 아웃박스 테이블 ────────────────────────────────────────────────
create table if not exists public.gsheet_sync_outbox (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('sale', 'inventory', 'ping')),
  dedupe_key text,
  rows jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'sent', 'confirmed', 'failed')),
  attempts integer not null default 0,
  last_request_id bigint,
  last_error text,
  sent_at timestamptz,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.gsheet_sync_outbox is
  '구글시트 동기화 아웃박스 — 전송 페이로드·상태·재시도 추적. 스윕: gsheet_sync_sweep() (pg_cron 5분)';
comment on column public.gsheet_sync_outbox.dedupe_key is
  'sale=주문번호, inventory=일련번호 (사람 식별용 — 실제 멱등성은 Apps Script가 시트 기준으로 판단)';

create index if not exists idx_gsheet_sync_outbox_active
  on public.gsheet_sync_outbox (status, id)
  where status in ('pending', 'sent');

alter table public.gsheet_sync_outbox enable row level security;
revoke all on table public.gsheet_sync_outbox from anon, authenticated;

-- ── 2) 페이로드 빌더 (트리거·재전송 공용) ─────────────────────────────
create or replace function public.build_gsheet_sale_rows(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.orders%rowtype;
  v_rows jsonb;
  v_pay text;
  v_paid_at text;
  v_buyer record;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return null;
  end if;

  v_pay := case o.payment_method
    when 'bank_transfer' then '무통장 입금'
    when 'card' then '카드(토스)'
    when 'toss_pay' then '토스페이'
    when 'kakao_pay' then '카카오페이'
    when 'naver_pay' then '네이버페이'
    else coalesce(o.payment_method, '-')
  end;
  v_paid_at := to_char(
    coalesce(o.paid_at, o.pg_approved_at, now()) at time zone 'Asia/Seoul',
    'YYYY-MM-DD HH24:MI:SS'
  );

  select p.name, p.email, p.phone into v_buyer
  from public.member_profiles p
  where p.user_id = o.user_id;

  -- 키는 시트 1행 헤더명과 동일해야 함 (Apps Script가 헤더로 열 매핑)
  select jsonb_agg(jsonb_build_object(
    '주문 번호', o.order_number,
    '주문 상태', '처리 중',
    '주문 일시', to_char(o.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI:SS'),
    '판매 채널', '수북 웹',
    '상품 이름', oi.title,
    '상품 옵션 정보', coalesce(oi.option_label, ''),
    '단일 정가', b.original_price,
    '단일 판매가', oi.unit_price,
    '구매 수량', oi.quantity,
    '상품 총액', oi.total_price,
    '배송 방식 이름', '일반택배',
    '배송비', coalesce(o.shipping_fee, 0),
    '상품 합계 금액', coalesce(o.subtotal, 0),
    '주문 할인 합계 금액', coalesce(o.discount_amount, 0) + coalesce(o.coupon_discount_amount, 0),
    '주문 금액', coalesce(o.total_amount, 0),
    '결제 상태', '결제 완료',
    '결제 완료 금액', coalesce(o.total_amount, 0),
    '결제1 - 결제 수단', v_pay,
    '결제1 - 결제 금액', coalesce(o.total_amount, 0),
    '결제1 - 결제 일시', v_paid_at,
    '회원 여부', case when o.user_id is null then '비회원' else '회원' end,
    '주문자명', coalesce(v_buyer.name, o.shipping_recipient_name, ''),
    '주문자 이메일', coalesce(v_buyer.email, ''),
    '주문자 핸드폰 번호', coalesce(v_buyer.phone, o.shipping_recipient_phone, ''),
    '수령인 이름', coalesce(o.shipping_recipient_name, ''),
    '수령인 핸드폰 번호', coalesce(o.shipping_recipient_phone, ''),
    '우편번호', coalesce(o.shipping_postal_code, ''),
    '주소', btrim(coalesce(o.shipping_address_line1, '') || ' ' || coalesce(o.shipping_address_line2, '')),
    '상품 위치', concat_ws(' / ', nullif(b.location, ''), b.serial_number::text)
  ) order by oi.id)
  into v_rows
  from public.order_items oi
  left join public.books b on b.id = oi.book_id
  where oi.order_id = o.id;

  return v_rows;
end;
$$;

create or replace function public.build_gsheet_inventory_rows(p_book_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bk public.books%rowtype;
  v_seller text;
begin
  select * into bk from public.books where id = p_book_id;
  if not found then
    return null;
  end if;

  select s.seller_name into v_seller
  from public.shipments s
  where s.id = bk.shipment_id;

  -- 새 DB 탭 열 순서 그대로: 일련번호-위치-수거신청자-상품명-판매가-옵션
  return jsonb_build_array(jsonb_build_array(
    bk.serial_number,
    coalesce(bk.location, ''),
    coalesce(v_seller, ''),
    coalesce(bk.title, ''),
    bk.price,
    coalesce(bk.option, '')
  ));
end;
$$;

-- ── 3) 큐 적재 + 즉시 발사 ────────────────────────────────────────────
create or replace function public.gsheet_sync_enqueue(
  p_kind text,
  p_dedupe_key text,
  p_rows jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_token text;
  v_id bigint;
  v_req bigint;
begin
  if p_rows is null then
    return;
  end if;

  -- 시크릿 미등록이면 큐에도 넣지 않는다 — URL을 지워 대량작업 유입을 차단하는
  -- 운영 관행이 있어, 여기서 적재하면 재등록 순간 시트로 쏟아진다.
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token
  from vault.decrypted_secrets where name = 'gsheet_sync_token' limit 1;
  if v_url is null or btrim(v_url) = '' or v_token is null then
    return;
  end if;

  insert into public.gsheet_sync_outbox (kind, dedupe_key, rows)
  values (p_kind, p_dedupe_key, p_rows)
  returning id into v_id;

  -- 즉시 1차 발사 — 실패해도 pending으로 남아 스윕이 이어받는다
  begin
    v_req := net.http_post(
      url := v_url,
      body := jsonb_build_object('token', v_token, 'kind', p_kind, 'rows', p_rows),
      timeout_milliseconds := 25000
    );
    update public.gsheet_sync_outbox
       set status = 'sent', attempts = 1, last_request_id = v_req,
           sent_at = now(), updated_at = now()
     where id = v_id;
  exception when others then
    null;
  end;
end;
$$;

-- ── 4) 트리거 함수 → 아웃박스 경유로 재정의 (발화 조건·트리거는 불변) ──
create or replace function public.notify_gsheet_order_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.gsheet_sync_enqueue(
    'sale', new.order_number, public.build_gsheet_sale_rows(new.id)
  );
  return new;
exception when others then
  -- 시트 기록 실패가 결제 확인을 막으면 안 됨
  return new;
end;
$$;

create or replace function public.notify_gsheet_book_registered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.gsheet_sync_enqueue(
    'inventory', new.serial_number::text, public.build_gsheet_inventory_rows(new.id)
  );
  return new;
exception when others then
  -- 시트 기록 실패가 재고 등록을 막으면 안 됨
  return new;
end;
$$;

-- ── 5) 스윕 — 응답 확인·재시도 (pg_cron 5분) ──────────────────────────
create or replace function public.gsheet_sync_sweep()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_token text;
  r record;
  v_resp record;
  v_req bigint;
  v_ping_ok boolean;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'gsheet_sync_webhook_url' limit 1;
  select decrypted_secret into v_token
  from vault.decrypted_secrets where name = 'gsheet_sync_token' limit 1;
  if v_url is null or btrim(v_url) = '' or v_token is null then
    return; -- 시크릿 제거 = 동기화 정지 상태 (대량작업 관행)
  end if;

  -- (a) sent 응답 확인 — Apps Script는 성공 시 {"ok":true,...} JSON을 준다
  for r in
    select * from public.gsheet_sync_outbox where status = 'sent'
  loop
    select * into v_resp from net._http_response where id = r.last_request_id;
    if found then
      if v_resp.status_code = 200
         and position('"ok":true' in coalesce(v_resp.content, '')) > 0 then
        update public.gsheet_sync_outbox
           set status = 'confirmed', confirmed_at = now(),
               last_error = null, updated_at = now()
         where id = r.id;
      elsif v_resp.status_code = 200
            and (coalesce(v_resp.content, '') like '%unauthorized%'
                 or coalesce(v_resp.content, '') like '%unknown kind%'
                 or coalesce(v_resp.content, '') like '%not found%') then
        -- 토큰 불일치·탭 이름 변경·구버전 스크립트의 ping 거부 — 재시도 무의미
        update public.gsheet_sync_outbox
           set status = 'failed', last_error = left(v_resp.content, 300),
               updated_at = now()
         where id = r.id;
      else
        -- 타임아웃·5xx·기타 — 재시도 대상
        update public.gsheet_sync_outbox
           set status = 'pending',
               last_error = left(coalesce(v_resp.error_msg, v_resp.content,
                                          'http ' || coalesce(v_resp.status_code::text, 'null')), 300),
               updated_at = now()
         where id = r.id;
      end if;
    elsif r.sent_at < now() - interval '20 minutes' then
      -- 응답 행 유실(pg_net TTL 6h·워커 재시작 등) — 재시도 대상
      update public.gsheet_sync_outbox
         set status = 'pending', last_error = 'no response row', updated_at = now()
       where id = r.id;
    end if;
  end loop;

  -- (b) 재시도 소진 → failed
  update public.gsheet_sync_outbox
     set status = 'failed', updated_at = now()
   where status = 'pending' and attempts >= 10;

  -- (c) 보낼 것 없으면 종료
  if not exists (
    select 1 from public.gsheet_sync_outbox
    where status = 'pending' and attempts < 10 and kind <> 'ping'
  ) then
    -- 정리: 오래된 ping 잔재
    delete from public.gsheet_sync_outbox
     where kind = 'ping' and status = 'failed' and created_at < now() - interval '2 days';
    return;
  end if;

  -- (d) ping 게이트 — v2 스크립트(멱등성 보유)가 확인되기 전에는 재전송 금지.
  --     구버전 스크립트는 중복 스킵이 없어 재전송이 곧 중복 행이다.
  select exists (
    select 1 from public.gsheet_sync_outbox where kind = 'ping' and status = 'confirmed'
  ) into v_ping_ok;

  if not v_ping_ok then
    if not exists (
      select 1 from public.gsheet_sync_outbox
      where kind = 'ping' and created_at > now() - interval '10 minutes'
    ) then
      insert into public.gsheet_sync_outbox (kind, dedupe_key, rows)
      values ('ping', null, '[]'::jsonb)
      returning id into r;
      begin
        v_req := net.http_post(
          url := v_url,
          body := jsonb_build_object('token', v_token, 'kind', 'ping'),
          timeout_milliseconds := 25000
        );
        update public.gsheet_sync_outbox
           set status = 'sent', attempts = 1, last_request_id = v_req,
               sent_at = now(), updated_at = now()
         where id = r.id;
      exception when others then
        null;
      end;
    end if;
    return;
  end if;

  -- (e) 재전송 — 회당 2건 직렬화 (동시 다발 doPost 락 경합을 만들지 않기 위해)
  for r in
    select * from public.gsheet_sync_outbox
    where status = 'pending' and attempts < 10 and kind <> 'ping'
    order by id
    limit 2
    for update skip locked
  loop
    begin
      v_req := net.http_post(
        url := v_url,
        body := jsonb_build_object('token', v_token, 'kind', r.kind,
                                   'rows', coalesce(r.rows, '[]'::jsonb)),
        timeout_milliseconds := 25000
      );
      update public.gsheet_sync_outbox
         set status = 'sent', attempts = attempts + 1, last_request_id = v_req,
             sent_at = now(), updated_at = now()
       where id = r.id;
    exception when others then
      null;
    end;
  end loop;
end;
$$;

-- ── 6) 수동 재전송 헬퍼 — 누락 주문 시딩 (전송은 스윕이 담당) ─────────
create or replace function public.admin_gsheet_resend_order(p_order_number text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id bigint;
  v_rows jsonb;
  v_id bigint;
begin
  select id into v_order_id from public.orders where order_number = p_order_number;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;

  v_rows := public.build_gsheet_sale_rows(v_order_id);
  if v_rows is null then
    return jsonb_build_object('ok', false, 'reason', 'no_items');
  end if;

  insert into public.gsheet_sync_outbox (kind, dedupe_key, rows)
  values ('sale', p_order_number, v_rows)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'outbox_id', v_id);
end;
$$;

-- ── 7) 권한 — 전부 서버 전용 ─────────────────────────────────────────
revoke all on function public.build_gsheet_sale_rows(bigint) from public, anon, authenticated;
revoke all on function public.build_gsheet_inventory_rows(bigint) from public, anon, authenticated;
revoke all on function public.gsheet_sync_enqueue(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.gsheet_sync_sweep() from public, anon, authenticated;
revoke all on function public.admin_gsheet_resend_order(text) from public, anon, authenticated;
grant execute on function public.gsheet_sync_sweep() to service_role;
grant execute on function public.admin_gsheet_resend_order(text) to service_role;

-- ── 8) 스윕 크론 (5분) — jobname 동일하면 갱신 ────────────────────────
select cron.schedule(
  'subook-gsheet-sync-sweep',
  '*/5 * * * *',
  $job$ select public.gsheet_sync_sweep(); $job$
);

commit;
