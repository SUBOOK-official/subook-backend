-- 알림톡 발송 로그 테이블
create table if not exists public.notification_logs (
  id bigint generated always as identity primary key,

  -- 수신자
  recipient_user_id uuid null references auth.users(id) on delete set null,
  recipient_phone text not null,
  recipient_name text null,

  -- 알림 유형
  notification_type text not null
    check (notification_type in (
      'pickup_accepted',    -- 수거접수 완료
      'arrived',            -- 입고 완료
      'inspection_done',    -- 검수 완료
      'sold',               -- 판매 완료
      'settlement_done',    -- 정산 완료
      'order_confirmed',    -- 주문 확인
      'shipping_started',   -- 배송 시작
      'delivery_done'       -- 배송 완료
    )),

  -- 연관 엔티티
  ref_type text null check (ref_type is null or ref_type in ('pickup_request', 'shipment', 'order', 'settlement')),
  ref_id bigint null,

  -- 카카오 알림톡
  template_code text not null,
  template_variables jsonb not null default '{}'::jsonb,
  message_body text not null,

  -- 발송 결과
  status text not null default 'pending'
    check (status in ('pending', 'sent', 'failed', 'fallback_sms')),
  vendor_message_id text null,
  error_message text null,
  sent_at timestamptz null,

  created_at timestamptz not null default now()
);

-- 인덱스
create index if not exists idx_notification_logs_recipient_user_id
  on public.notification_logs (recipient_user_id, created_at desc);

create index if not exists idx_notification_logs_type
  on public.notification_logs (notification_type, created_at desc);

create index if not exists idx_notification_logs_ref
  on public.notification_logs (ref_type, ref_id)
  where ref_type is not null;

create index if not exists idx_notification_logs_status
  on public.notification_logs (status)
  where status in ('pending', 'failed');

-- RLS
alter table public.notification_logs enable row level security;

-- 사용자는 자기 알림 로그만 조회 가능
create policy "notification_logs_select_own"
  on public.notification_logs for select
  to authenticated
  using (recipient_user_id = auth.uid());

-- admin 전체 접근
create policy "notification_logs_admin_all"
  on public.notification_logs for all
  to authenticated
  using (public.is_admin_user());

-- 관리자 알림 로그 조회 RPC
create or replace function public.list_admin_notification_logs(
  p_notification_type text default null,
  p_status text default null,
  p_ref_type text default null,
  p_ref_id bigint default null,
  p_from_date date default null,
  p_to_date date default null,
  p_limit integer default 50,
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

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', nl.id,
      'recipient_phone', nl.recipient_phone,
      'recipient_name', nl.recipient_name,
      'notification_type', nl.notification_type,
      'ref_type', nl.ref_type,
      'ref_id', nl.ref_id,
      'template_code', nl.template_code,
      'message_body', nl.message_body,
      'status', nl.status,
      'error_message', nl.error_message,
      'sent_at', nl.sent_at,
      'created_at', nl.created_at
    ) as row_data
    from public.notification_logs nl
    where
      (p_notification_type is null or nl.notification_type = p_notification_type)
      and (p_status is null or nl.status = p_status)
      and (p_ref_type is null or nl.ref_type = p_ref_type)
      and (p_ref_id is null or nl.ref_id = p_ref_id)
      and (p_from_date is null or nl.created_at >= p_from_date)
      and (p_to_date is null or nl.created_at < p_to_date + interval '1 day')
    order by nl.created_at desc
    limit p_limit offset p_offset
  ) sub;

  return v_result;
end;
$$;
