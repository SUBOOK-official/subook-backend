-- 신규 migration을 같은 트랜잭션에 로드한 뒤 실행하고 전체 ROLLBACK한다.
do $test$
declare
  v_rows jsonb;
  v_result jsonb;
  v_start timestamptz := now() - interval '1 hour';
begin
  if has_function_privilege('anon', 'public.sync_meta_catalog_snapshot(text,jsonb,timestamptz)', 'execute')
    or has_function_privilege('authenticated', 'public.sync_meta_catalog_snapshot(text,jsonb,timestamptz)', 'execute') then
    raise exception 'Catalog RPC must be server-only';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.meta_catalog_snapshots'::regclass) then
    raise exception 'Catalog RLS missing';
  end if;
  if has_table_privilege('anon', 'public.meta_catalog_snapshots', 'select')
    or has_table_privilege('authenticated', 'public.meta_catalog_snapshots', 'update') then
    raise exception 'Catalog table permissions too broad';
  end if;
  select jsonb_agg(jsonb_build_object('id', i::text, 'title', '공개 테스트 교재', 'price', '1000 KRW', 'availability', 'in stock'))
    into v_rows from generate_series(1, 1005) i;
  v_result := public.sync_meta_catalog_snapshot('all', v_rows, v_start);
  if jsonb_array_length(v_result) <> 1005 then raise exception 'Snapshot truncated'; end if;
  -- 마지막 재고 판매/관리자 숨김으로 현재 공개 목록이 줄어도 기존 ID는 품절로 유지.
  v_result := public.sync_meta_catalog_snapshot('all', '[{"id":"1","price":"2000 KRW","availability":"in stock"}]', v_start + interval '1 second');
  if jsonb_array_length(v_result) <> 1005 or
    (select count(*) from jsonb_array_elements(v_result) r where r->>'availability' = 'out of stock') <> 1004 then
    raise exception 'Sold-out IDs lost';
  end if;
  -- 오래된 요청/동일 요청 재시도가 가격·재고를 되돌리지 않음.
  perform public.sync_meta_catalog_snapshot('all', v_rows, v_start);
  if (select payload->>'price' from public.meta_catalog_snapshots where scope='all' and content_id='1') <> '2000 KRW' then
    raise exception 'Stale snapshot overwrote fresh data';
  end if;
  v_result := public.sync_meta_catalog_snapshot('all', '[]', v_start + interval '2 seconds');
  if jsonb_array_length(v_result) <> 1005 or exists
    (select 1 from jsonb_array_elements(v_result) r where r->>'availability' <> 'out of stock') then
    raise exception 'Empty public inventory lost history';
  end if;
  v_result := public.sync_meta_catalog_snapshot('jeonil', '[{"id":"gxav9zwrza","availability":"in stock"}]', v_start);
  if jsonb_array_length(v_result) <> 1 then raise exception 'Scope isolation failed'; end if;
  begin
    perform public.sync_meta_catalog_snapshot('jeonil', '[{"id":"2500","availability":"in stock"}]', v_start);
    raise exception 'Invalid Jeonil ID accepted';
  exception when raise_exception then
    if sqlerrm <> 'Invalid catalog items' then raise; end if;
  end;
  begin
    perform public.sync_meta_catalog_snapshot('all', '[{"id":"1"}]', v_start);
    raise exception 'Invalid payload accepted';
  exception when raise_exception then
    if sqlerrm <> 'Invalid catalog items' then raise; end if;
  end;
end;
$test$;
set local role service_role;
select jsonb_array_length(public.sync_meta_catalog_snapshot('jeonil', '[]', now())) = 1 as service_role_can_sync;
reset role;
