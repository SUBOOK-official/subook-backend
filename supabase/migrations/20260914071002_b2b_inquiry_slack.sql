-- B2B 교재 공급 문의를 주문/수거 알림과 같은 팀 운영 Slack 채널로 전달한다.
--
-- 브라우저가 Slack 웹훅이나 service_role 키를 직접 보지 않도록 public-web 서버리스
-- 함수가 이 RPC를 service_role로 호출한다. 문의 원문은 별도 DB 테이블에 보관하지 않고
-- Slack으로만 전달하며, 아래 키 테이블에는 네트워크 재시도 중복 방지용 접수번호만 남긴다.
-- pg_net은 트랜잭션 커밋 후 비동기로 발송하므로 같은 접수번호 재호출은 한 번만 큐잉한다.
--
-- 롤백:
--   drop function if exists public.queue_b2b_inquiry_slack(jsonb);
--   drop table if exists public.b2b_inquiry_delivery_keys;

begin;

create table public.b2b_inquiry_delivery_keys (
  reference_id text primary key,
  slack_request_id bigint,
  created_at timestamptz not null default now(),
  constraint b2b_inquiry_delivery_keys_reference_format_check
    check (reference_id ~ '^B2B-[0-9]{8}-[A-F0-9]{6}$')
);

alter table public.b2b_inquiry_delivery_keys enable row level security;
revoke all on table public.b2b_inquiry_delivery_keys from public;
revoke all on table public.b2b_inquiry_delivery_keys from anon;
revoke all on table public.b2b_inquiry_delivery_keys from authenticated;
grant select, insert, update on table public.b2b_inquiry_delivery_keys to service_role;

create or replace function public.queue_b2b_inquiry_slack(p_inquiry jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_reference_id text;
  v_organization text;
  v_contact_name text;
  v_phone text;
  v_email text;
  v_quantity integer;
  v_interests text;
  v_request_details text;
  v_inserted_reference text;
  v_recent_count integer;
  v_request_id bigint;
  v_blocks jsonb;
begin
  if p_inquiry is null or jsonb_typeof(p_inquiry) <> 'object' then
    raise exception 'INVALID_B2B_INQUIRY';
  end if;

  v_reference_id := btrim(coalesce(p_inquiry ->> 'referenceId', ''));
  v_organization := btrim(coalesce(p_inquiry ->> 'organization', ''));
  v_contact_name := btrim(coalesce(p_inquiry ->> 'contactName', ''));
  v_phone := regexp_replace(coalesce(p_inquiry ->> 'phone', ''), '[^0-9]', '', 'g');
  v_email := lower(btrim(coalesce(p_inquiry ->> 'email', '')));
  v_interests := btrim(coalesce(p_inquiry ->> 'interests', ''));
  v_request_details := btrim(coalesce(p_inquiry ->> 'requestDetails', ''));

  begin
    v_quantity := (p_inquiry ->> 'quantity')::integer;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'INVALID_B2B_QUANTITY';
  end;

  if v_reference_id !~ '^B2B-[0-9]{8}-[A-F0-9]{6}$' then
    raise exception 'INVALID_B2B_REFERENCE';
  end if;
  if v_organization = '' or char_length(v_organization) > 100 then
    raise exception 'INVALID_B2B_ORGANIZATION';
  end if;
  if v_contact_name = '' or char_length(v_contact_name) > 50 then
    raise exception 'INVALID_B2B_CONTACT_NAME';
  end if;
  if v_phone !~ '^01[016789][0-9]{7,8}$' then
    raise exception 'INVALID_B2B_PHONE';
  end if;
  if v_email <> '' and (
    char_length(v_email) > 254
    or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  ) then
    raise exception 'INVALID_B2B_EMAIL';
  end if;
  if v_quantity < 1 or v_quantity > 1000000 then
    raise exception 'INVALID_B2B_QUANTITY';
  end if;
  if char_length(v_interests) > 500 or char_length(v_request_details) > 2000 then
    raise exception 'INVALID_B2B_DETAILS';
  end if;
  if coalesce((p_inquiry ->> 'privacyConsent')::boolean, false) is not true then
    raise exception 'B2B_PRIVACY_CONSENT_REQUIRED';
  end if;

  -- 동일 referenceId 재시도는 성공으로 응답하되 Slack에는 중복 발송하지 않는다.
  if exists (
    select 1 from public.b2b_inquiry_delivery_keys where reference_id = v_reference_id
  ) then
    return jsonb_build_object(
      'queued', true,
      'duplicate', true,
      'referenceId', v_reference_id
    );
  end if;

  -- 공개 폼의 자동화 스팸이 팀 채널을 도배하지 않도록 짧은 전역 상한을 둔다.
  -- 동시 요청도 상한을 우회하지 못하게 advisory lock 안에서 재확인·집계한다.
  perform pg_advisory_xact_lock(hashtextextended('queue_b2b_inquiry_slack', 0));

  if exists (
    select 1 from public.b2b_inquiry_delivery_keys where reference_id = v_reference_id
  ) then
    return jsonb_build_object(
      'queued', true,
      'duplicate', true,
      'referenceId', v_reference_id
    );
  end if;

  delete from public.b2b_inquiry_delivery_keys
  where created_at < now() - interval '90 days';

  select count(*)::integer into v_recent_count
  from public.b2b_inquiry_delivery_keys
  where created_at >= now() - interval '10 minutes';

  if v_recent_count >= 20 then
    raise exception 'B2B_INQUIRY_RATE_LIMITED';
  end if;

  insert into public.b2b_inquiry_delivery_keys (reference_id)
  values (v_reference_id)
  on conflict (reference_id) do nothing
  returning reference_id into v_inserted_reference;

  if v_inserted_reference is null then
    return jsonb_build_object(
      'queued', true,
      'duplicate', true,
      'referenceId', v_reference_id
    );
  end if;

  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'slack_ops_webhook_url'
  limit 1;

  if v_url is null or btrim(v_url) = '' then
    -- 예외로 트랜잭션을 되돌려, 웹훅 복구 뒤 같은 referenceId로 재시도할 수 있게 한다.
    raise exception 'B2B_SLACK_WEBHOOK_NOT_CONFIGURED';
  end if;

  -- Slack mrkdwn의 링크·멘션 문법(<...>)을 사용자 입력으로 주입하지 못하게 이스케이프한다.
  v_organization := replace(replace(replace(v_organization, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_contact_name := replace(replace(replace(v_contact_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_email := replace(replace(replace(v_email, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_interests := replace(replace(replace(v_interests, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_request_details := replace(replace(replace(v_request_details, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

  v_blocks := jsonb_build_array(
    jsonb_build_object(
      'type', 'header',
      'text', jsonb_build_object('type', 'plain_text', 'text', '🏫 새 B2B 교재 공급 문의')
    ),
    jsonb_build_object(
      'type', 'section',
      'fields', jsonb_build_array(
        jsonb_build_object('type', 'mrkdwn', 'text', format(E'*기관명*\n%s', v_organization)),
        jsonb_build_object('type', 'mrkdwn', 'text', format(E'*담당자*\n%s', v_contact_name)),
        jsonb_build_object('type', 'mrkdwn', 'text', format(E'*연락처*\n%s', v_phone)),
        jsonb_build_object('type', 'mrkdwn', 'text', format(E'*예상 수량*\n%s권', to_char(v_quantity, 'FM999,999,999')))
      )
    ),
    jsonb_build_object(
      'type', 'context',
      'elements', jsonb_build_array(
        jsonb_build_object('type', 'mrkdwn', 'text', format('접수번호 `%s` · subook.kr/b2b', v_reference_id))
      )
    )
  );

  if v_email <> '' then
    v_blocks := v_blocks || jsonb_build_array(
      jsonb_build_object('type', 'section', 'text', jsonb_build_object(
        'type', 'mrkdwn', 'text', format(E'*이메일*\n%s', v_email)
      ))
    );
  end if;
  if v_interests <> '' then
    v_blocks := v_blocks || jsonb_build_array(
      jsonb_build_object('type', 'section', 'text', jsonb_build_object(
        'type', 'mrkdwn', 'text', format(E'*관심 과목·교재*\n%s', left(v_interests, 500))
      ))
    );
  end if;
  if v_request_details <> '' then
    v_blocks := v_blocks || jsonb_build_array(
      jsonb_build_object('type', 'section', 'text', jsonb_build_object(
        'type', 'mrkdwn', 'text', format(E'*요청사항*\n%s', left(v_request_details, 2000))
      ))
    );
  end if;

  select net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'text', format('새 B2B 교재 공급 문의 — %s · %s권 · %s', v_organization, v_quantity, v_reference_id),
      'blocks', v_blocks
    ),
    timeout_milliseconds := 5000
  ) into v_request_id;

  update public.b2b_inquiry_delivery_keys
  set slack_request_id = v_request_id
  where reference_id = v_reference_id;

  return jsonb_build_object(
    'queued', true,
    'duplicate', false,
    'referenceId', v_reference_id,
    'requestId', v_request_id
  );
end;
$$;

revoke all on function public.queue_b2b_inquiry_slack(jsonb) from public;
revoke all on function public.queue_b2b_inquiry_slack(jsonb) from anon;
revoke all on function public.queue_b2b_inquiry_slack(jsonb) from authenticated;
grant execute on function public.queue_b2b_inquiry_slack(jsonb) to service_role;

commit;
