-- 2026-11-13 보안 감사 후속: 계좌번호 암호화 키 교체 + 저장된 암호문 재암호화
--
-- 배경: get_account_encryption_key()가 사이트 공개 키만으로 호출 가능했다(20261113131542로 차단).
--       노출 기간에 키가 유출됐을 가능성을 배제할 수 없어 키를 교체한다.
--
-- 동작 (전부 하나의 DO 문 = 하나의 트랜잭션, 실패 시 전체 롤백):
--   1) 키 행 잠금 + 암호문 테이블 4개 쓰기 잠금
--   2) 새 키를 DB 안에서 생성 (gen_random_bytes — 키 값은 DB 밖으로 나오지 않는다)
--   3) 행마다 옛 키로 복호화 → 새 키로 암호화 → 새 키로 다시 풀어 원문과 같은지 확인 후 저장
--      (옛 키로도 안 풀리는 행은 교체 전부터 읽을 수 없던 데이터 — 그대로 두고 건수만 센다)
--   4) 키 교체, 옛 키는 account_encryption_key_prev_20261113 로 보관(되돌리기용)
--   5) 운영 함수(decrypt_account_number) 경로로 전 행을 다시 읽어 검증
-- 트리거: 대상 테이블에서 켜져 있던 사용자 트리거만 이 트랜잭션 안에서 껐다가 그대로 다시 켠다
--        (암호문만 바뀌므로 updated_at 갱신·슬랙·시트 동기화 등이 따라 돌지 않게).
--        실패하면 롤백으로 트리거 상태도 원복된다. session_replication_role은 권한이 없어 쓰지 않는다.
-- 재실행: 보관 키 행이 있으면 아무것도 하지 않는다(멱등). 키가 없는 DB(로컬)도 건너뛴다.
-- 되돌리기: 보관 키와 현재 키를 맞바꾸는 같은 절차를 실행. 문제없이 운영되면 보관 키 행은 삭제한다.
-- 대상: member_settlement_accounts / pickup_requests / shipments / settlements 의 암호문 컬럼.

do $rotate$
declare
  c_prev_key constant text := 'account_encryption_key_prev_20261113';
  c_opts constant text := 'cipher-algo=aes256, compress-algo=0';
  c_targets constant text[] := array[
    'member_settlement_accounts:account_number_ciphertext',
    'pickup_requests:settlement_account_number_ciphertext',
    'shipments:settlement_account_number_ciphertext',
    'settlements:account_number_ciphertext'
  ];
  v_old text;
  v_new text;
  v_target text;
  v_tbl text;
  v_col text;
  v_id bigint;
  v_ct bytea;
  v_plain text;
  v_new_ct bytea;
  v_done integer;
  v_skip integer;
  v_skip_total integer := 0;
  v_unreadable integer;
  v_summary text := '';
  v_trg_tbls text[] := '{}';
  v_trg_names text[] := '{}';
  v_trg_tbl text;
  v_trg_name text;
  v_i integer;
begin
  select value into v_old from private.app_secrets where key = 'account_encryption_key' for update;
  if v_old is null or v_old = '' then
    raise notice 'account_encryption_key 미설정 — 키 교체를 건너뜁니다.';
    return;
  end if;
  if exists (select 1 from private.app_secrets where key = c_prev_key) then
    raise notice '이미 교체된 상태(%) — 건너뜁니다.', c_prev_key;
    return;
  end if;

  perform set_config('lock_timeout', '15s', true);
  lock table public.member_settlement_accounts, public.pickup_requests, public.shipments, public.settlements
    in share row exclusive mode;
  -- 켜져 있던 사용자 트리거만 기록해 두고 끈다 (원래 꺼져 있던 트리거는 건드리지 않는다)
  for v_trg_tbl, v_trg_name in
    select c.relname, t.tgname
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('member_settlement_accounts', 'pickup_requests', 'shipments', 'settlements')
      and not t.tgisinternal
      and t.tgenabled = 'O'
    order by c.relname, t.tgname
  loop
    execute format('alter table public.%I disable trigger %I', v_trg_tbl, v_trg_name);
    v_trg_tbls := v_trg_tbls || v_trg_tbl;
    v_trg_names := v_trg_names || v_trg_name;
  end loop;

  v_new := encode(extensions.gen_random_bytes(32), 'hex');

  foreach v_target in array c_targets loop
    v_tbl := split_part(v_target, ':', 1);
    v_col := split_part(v_target, ':', 2);
    v_done := 0;
    v_skip := 0;
    for v_id, v_ct in
      execute format('select id, %I from public.%I where %I is not null order by id', v_col, v_tbl, v_col)
    loop
      begin
        v_plain := extensions.pgp_sym_decrypt(v_ct, v_old);
      exception when others then
        v_skip := v_skip + 1;
        continue;
      end;
      v_new_ct := extensions.pgp_sym_encrypt(v_plain, v_new, c_opts);
      if extensions.pgp_sym_decrypt(v_new_ct, v_new) is distinct from v_plain then
        raise exception '재암호화 검증 실패: %.% id=%', v_tbl, v_col, v_id;
      end if;
      execute format('update public.%I set %I = $1 where id = $2', v_tbl, v_col) using v_new_ct, v_id;
      v_done := v_done + 1;
    end loop;
    v_skip_total := v_skip_total + v_skip;
    v_summary := v_summary || format('%s 재암호화 %s건·건너뜀 %s건 / ', v_tbl, v_done, v_skip);
  end loop;

  insert into private.app_secrets (key, value) values (c_prev_key, v_old);
  update private.app_secrets set value = v_new, updated_at = now() where key = 'account_encryption_key';

  -- 운영 함수 경로로 최종 확인: 새 키로 읽히지 않는 행은 교체 전부터 읽히지 않던 행뿐이어야 한다.
  select
      (select count(*) from public.member_settlement_accounts
        where account_number_ciphertext is not null
          and public.decrypt_account_number(account_number_ciphertext) is null)
    + (select count(*) from public.pickup_requests
        where settlement_account_number_ciphertext is not null
          and public.decrypt_account_number(settlement_account_number_ciphertext) is null)
    + (select count(*) from public.shipments
        where settlement_account_number_ciphertext is not null
          and public.decrypt_account_number(settlement_account_number_ciphertext) is null)
    + (select count(*) from public.settlements
        where account_number_ciphertext is not null
          and public.decrypt_account_number(account_number_ciphertext) is null)
  into v_unreadable;
  if v_unreadable <> v_skip_total then
    raise exception '교체 후 검증 실패: 새 키로 읽히지 않는 행 %건 (교체 전부터 읽히지 않던 행 %건)',
      v_unreadable, v_skip_total;
  end if;

  -- 껐던 트리거를 그대로 다시 켠다
  for v_i in 1 .. coalesce(array_length(v_trg_names, 1), 0) loop
    execute format('alter table public.%I enable trigger %I', v_trg_tbls[v_i], v_trg_names[v_i]);
  end loop;
  if exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and (c.relname, t.tgname) in (select * from unnest(v_trg_tbls, v_trg_names))
      and t.tgenabled <> 'O'
  ) then
    raise exception '트리거 원복 검증 실패';
  end if;

  v_summary := v_summary || format('트리거 %s개 일시 비활성 후 복구 / 새 키 길이 %s',
    coalesce(array_length(v_trg_names, 1), 0), length(v_new));
  raise notice '계좌 암호화 키 교체 완료 — %', v_summary;
  -- [DRY-RUN-HOOK]
end
$rotate$;
