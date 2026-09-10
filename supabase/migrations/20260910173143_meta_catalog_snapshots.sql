-- Meta 피드에서 한 번 공개한 상품의 마지막 공개 필드만 보존한다.
-- 수북은 판매 후 books.is_public=false/products.hidden으로 바뀌므로 현재 목록만으로는
-- 품절 상품 ID를 유지할 수 없다. 기존 상품/주문/결제 테이블·트리거는 변경하지 않는다.
-- 롤백: 피드 예약을 중지하고 API 이전 버전 배포. 이 전용 테이블은 보존해도 다른 기능 영향 없음.
begin;

create table public.meta_catalog_snapshots (
  scope text not null check (scope in ('jeonil', 'all')),
  content_id text not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object' and payload->>'id' = content_id),
  observed_at timestamptz not null,
  primary key (scope, content_id)
);

comment on table public.meta_catalog_snapshots is
  'Meta에 공급했던 공개 상품 필드만 저장. 현재 공개 목록에서 빠지면 마지막 필드+out of stock 유지. 서버 전용.';
alter table public.meta_catalog_snapshots enable row level security;
revoke all on table public.meta_catalog_snapshots from public, anon, authenticated;
grant select, insert, update on table public.meta_catalog_snapshots to service_role;

create function public.sync_meta_catalog_snapshot(p_scope text, p_rows jsonb, p_observed_at timestamptz)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_latest timestamptz;
  v_result jsonb;
begin
  if p_scope is null or p_scope not in ('jeonil', 'all')
    or p_rows is null or jsonb_typeof(p_rows) <> 'array'
    or p_observed_at is null or p_observed_at > now() + interval '1 minute' then
    raise exception 'Invalid catalog snapshot';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) r
    where coalesce(r->>'id', '') = '' or coalesce(r->>'availability', '') not in ('in stock', 'out of stock')
      or (p_scope = 'jeonil' and r->>'id' not in ('gxav9zwrza', '417vdy5t1z', 'n7llsz4qrh')))
    or (select count(*) from jsonb_array_elements(p_rows)) <>
       (select count(distinct r->>'id') from jsonb_array_elements(p_rows) r) then
    raise exception 'Invalid catalog items';
  end if;

  -- 같은 범위 요청을 직렬화하고 늦게 끝난 오래된 조회가 새 가격/재고를 덮지 못하게 한다.
  perform pg_advisory_xact_lock(1603666397, case when p_scope = 'jeonil' then 1 else 2 end);
  select max(observed_at) into v_latest from public.meta_catalog_snapshots where scope = p_scope;
  if v_latest is null or p_observed_at > v_latest then
    insert into public.meta_catalog_snapshots (scope, content_id, payload, observed_at)
      select p_scope, r->>'id', r, p_observed_at from jsonb_array_elements(p_rows) r
      on conflict (scope, content_id) do update
        set payload = excluded.payload, observed_at = excluded.observed_at;

    -- 이 함수 호출 시에만 전용 캐시를 갱신한다. 마이그레이션 적용 자체는 기존 데이터 변경 없음.
    update public.meta_catalog_snapshots s
      set payload = jsonb_set(s.payload, '{availability}', '"out of stock"'::jsonb),
          observed_at = p_observed_at
      where s.scope = p_scope and s.observed_at < p_observed_at;
  end if;
  select coalesce(jsonb_agg(payload order by content_id), '[]'::jsonb) into v_result
    from public.meta_catalog_snapshots where scope = p_scope;
  return v_result;
end;
$$;

revoke all on function public.sync_meta_catalog_snapshot(text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.sync_meta_catalog_snapshot(text, jsonb, timestamptz) to service_role;

commit;
