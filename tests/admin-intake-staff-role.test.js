// 교재 등록 담당(role=intake) 권한
//   20261116030246_admin_intake_staff_role.sql — 역할·허용 목록·사진 버킷
//   20261116031241_admin_intake_staff_masking_and_log.sql — 전화번호 가리기·허용 목록 축소·등록자 기록
//   20261116031639_admin_intake_targets_scope.sql — 등록 담당 목록은 진행 중인 건만
// 핵심: 등록 담당은 허용한 등록 RPC 요청에서만 is_admin_user()=true, 그 밖에는 전부 false.
import { before, after, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const superAdmin = "00000000-0000-0000-0000-000000000001";
const staff = "00000000-0000-0000-0000-000000000002";
const member = "00000000-0000-0000-0000-000000000003";
const q = async (sql, params = []) => (await db.query(sql, params)).rows;

// PostgREST가 요청마다 넣어 주는 설정을 흉내 낸다. path가 null이면 PostgREST 밖(Storage·직접 연결) 요청.
async function request({ uid = "", role = "authenticated", method = "POST", path = null, email = "" }) {
  await q(
    "select set_config('app.uid',$1,false), set_config('app.role',$2,false), set_config('request.method',$3,false), set_config('request.path',$4,false), set_config('app.email',$5,false)",
    [uid, role, path === null ? "" : method, path ?? "", email],
  );
}
const isAdmin = async () => (await q("select public.is_admin_user() as ok"))[0].ok;

before(async () => {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create table auth.users(id uuid primary key);
    insert into auth.users values('${superAdmin}'),('${staff}'),('${member}');
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.uid',true),'')::uuid$$;
    create function auth.role() returns text language sql stable as $$select nullif(current_setting('app.role',true),'')$$;
    create function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('email', nullif(current_setting('app.email',true),''))$$;
    grant usage on schema auth to anon, authenticated, service_role;

    create table public.admin_users(
      email text primary key, created_at timestamptz not null default now(), user_id uuid not null,
      role text not null default 'super',
      constraint admin_users_role_check check (role in ('super','ops','cs'))
    );
    -- 운영의 기존 정의 (2026051301_lockdown_rls_and_admin.sql)
    create function public.is_admin_user() returns boolean language sql stable security definer set search_path = public, auth as $$
      select coalesce(auth.role() = 'service_role', false)
        or exists (select 1 from public.admin_users where user_id = auth.uid());
    $$;
    grant execute on function public.is_admin_user() to authenticated, service_role;

    create table public.shipments(id bigint primary key, seller_name text, seller_phone text, pickup_date date, status text, secret_note text);
    insert into public.shipments values (7, '김샘플', '010-0000-0000', '2026-11-15', 'scheduled', '등록 담당에게 보이면 안 되는 값');
    alter table public.shipments enable row level security;
    create policy shipments_select_admin on public.shipments for select to authenticated using (public.is_admin_user());
    grant select on public.shipments to authenticated;

    create schema storage;
    create table storage.objects(id bigserial primary key, bucket_id text, name text, owner_id text);
    alter table storage.objects enable row level security;
    grant usage on schema storage to authenticated;
    grant select, insert, delete on storage.objects to authenticated;
    grant usage on sequence storage.objects_id_seq to authenticated;
    create policy "product-covers admin write" on storage.objects for insert with check (bucket_id = 'product-covers' and public.is_admin_user());
    create policy "read all" on storage.objects for select using (true);

    insert into public.admin_users(email, user_id, role) values ('owner@example.com', '${superAdmin}', 'super');

    -- 등록 대상 목록의 기존 두 함수(운영 정의의 반환 모양만 흉내)와 books
    create table public.pickup_targets(kind text, ref_id bigint, request_number text, seller_name text, seller_phone text,
      target_date date, status text, book_count integer, expected_book_count integer, box_count integer, user_id uuid,
      member_name text, sort_ts timestamptz);
    insert into public.pickup_targets values
      ('pickup_request', 11, 'PU-2611-0005', '나유찬', '010-1234-5678', '2026-11-15', 'arrived', 0, 12, 1, '${member}', '나유찬', '2026-11-15T03:00:00Z'),
      ('pickup_request', 12, 'PU-2611-0006', '김수북', '010-9999-0005', '2026-11-14', 'arrived', 3, 20, 2, null, null, '2026-11-14T03:00:00Z'),
      ('shipment', 7, null, '김샘플', '01055556789', '2026-11-13', 'scheduled', 0, null, 1, null, null, '2026-11-13T03:00:00Z'),
      -- 검수가 끝난 과거 건 — 관리자 검색에는 나오고 등록 담당에게는 안 보여야 한다
      ('pickup_request', 13, 'PU-2610-0001', '나유찬', '010-7777-5678', '2026-10-02', 'inspected', 9, 9, 1, null, null, '2026-10-02T03:00:00Z'),
      ('shipment', 8, null, '박과거', '010-2222-3333', '2026-09-01', 'inspected', 4, null, 1, null, null, '2026-09-01T03:00:00Z');
    create function public.admin_search_register_targets(p_search text, p_limit integer)
    returns table(kind text, ref_id bigint, request_number text, seller_name text, seller_phone text, target_date date,
      status text, book_count integer, expected_book_count integer, box_count integer, user_id uuid, member_name text, sort_ts timestamptz)
    language sql stable security definer set search_path = public as $$
      select * from public.pickup_targets t
      where public.is_admin_user()
        and (t.seller_name ilike '%' || p_search || '%' or t.request_number ilike '%' || p_search || '%'
          or (regexp_replace(p_search, '[^0-9]', '', 'g') <> ''
            and regexp_replace(t.seller_phone, '[^0-9]', '', 'g') like '%' || regexp_replace(p_search, '[^0-9]', '', 'g') || '%'))
      order by t.sort_ts desc limit p_limit;
    $$;
    create function public.admin_recent_intake_targets(p_limit integer, p_offset integer)
    returns jsonb language plpgsql stable security definer set search_path = public as $$
    begin
      if not public.is_admin_user() then raise exception 'Admin access required'; end if;
      return (select coalesce(jsonb_agg(to_jsonb(t) - 'member_name' order by t.sort_ts desc), '[]'::jsonb)
        from public.pickup_targets t where t.status in ('arrived', 'inspecting', 'scheduled'));
    end $$;
    create table public.books(id bigint primary key, shipment_id bigint, title text);
  `);
  await db.exec(await readFile(new URL("../supabase/migrations/20261116030246_admin_intake_staff_role.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../supabase/migrations/20261116031241_admin_intake_staff_masking_and_log.sql", import.meta.url), "utf8"));
  await db.exec(await readFile(new URL("../supabase/migrations/20261116031639_admin_intake_targets_scope.sql", import.meta.url), "utf8"));
  await q("insert into public.admin_users(email, user_id, role, display_name) values ('staff@example.com', $1, 'intake', '등록 알바')", [staff]);
});
after(() => db.close());

test("기존 관리자는 어떤 요청이든 그대로 관리자", async () => {
  for (const path of ["/rpc/admin_update_product_master", "/orders", "/rpc/is_admin_user", null]) {
    await request({ uid: superAdmin, path });
    assert.equal(await isAdmin(), true, String(path));
  }
  await request({ uid: "", role: "service_role", path: null });
  assert.equal(await isAdmin(), true, "service_role");
});

test("일반 회원·비로그인은 허용 경로에서도 관리자가 아니다", async () => {
  await request({ uid: member, path: "/rpc/admin_register_customer_inventory" });
  assert.equal(await isAdmin(), false);
  await request({ uid: "", role: "anon", path: "/rpc/admin_recent_intake_targets" });
  assert.equal(await isAdmin(), false);
});

test("등록 담당은 허용한 등록 RPC 요청에서만 통과한다", async () => {
  const allowed = [
    "admin_list_register_targets", "admin_start_inspection_from_pickup", "admin_get_register_shipment",
    "admin_search_products_for_register", "admin_suggest_register_price", "admin_suggest_book_type",
    "admin_get_register_sales_history", "admin_register_customer_inventory",
  ];
  for (const name of allowed) {
    await request({ uid: staff, path: `/rpc/${name}` });
    assert.equal(await isAdmin(), true, name);
  }
  await request({ uid: staff, path: "/rest/v1/rpc/admin_list_register_targets" });
  assert.equal(await isAdmin(), true, "게이트웨이 접두사가 붙은 경로");
});

test("등록 담당은 그 밖의 모든 요청에서 거부된다", async () => {
  const denied = [
    ["POST", "/rpc/is_admin_user"],                    // 서버리스 API들의 관리자 확인
    ["POST", "/rpc/admin_update_product_master"],      // 상품 이름·가격 수정
    ["POST", "/rpc/admin_create_direct_shipment_v2"],  // 새 고객 등록
    ["POST", "/rpc/list_admin_work_orders"],           // 주문
    ["POST", "/rpc/list_admin_members"],               // 회원
    ["POST", "/rpc/admin_issue_coupon_to_all"],        // 쿠폰
    ["POST", "/rpc/admin_recent_intake_targets"],      // 전화번호 원본을 주는 기존 목록 함수
    ["POST", "/rpc/admin_search_register_targets"],
    ["POST", "/rpc/admin_intake_catalog_metadata"],    // 등록 화면이 쓰지 않는 것
    ["POST", "/rpc/admin_intake_price_context"],
    ["POST", "/rpc/admin_staff_registration_stats"],   // 직원 계정 화면 전용
    ["POST", "/rpc/admin_list_register_targets_extra"], // 이름이 비슷한 다른 함수
    ["POST", "/rpc/xadmin_list_register_targets"],
    ["GET", "/rpc/admin_list_register_targets"],       // 허용 RPC라도 POST만
    ["GET", "/shipments"],                             // 테이블 직접 조회
    ["GET", "/orders"],
    ["POST", "/shipments"],
    ["POST", "/"],
  ];
  for (const [method, path] of denied) {
    await request({ uid: staff, method, path });
    assert.equal(await isAdmin(), false, `${method} ${path}`);
  }
  // PostgREST 밖의 요청(Storage·직접 연결)에는 경로가 없다 → 거부
  await request({ uid: staff, path: null });
  assert.equal(await isAdmin(), false, "경로 없음");
});

test("화면용 권한 조회는 역할을 구분해 돌려준다", async () => {
  const access = async () => (await q("select public.get_admin_access() as a"))[0].a;
  await request({ uid: superAdmin, path: "/rpc/get_admin_access" });
  assert.deepEqual(await access(), { role: "admin" });
  await request({ uid: staff, path: "/rpc/get_admin_access" });
  assert.deepEqual(await access(), { role: "intake" });
  await request({ uid: member, path: "/rpc/get_admin_access" });
  assert.deepEqual(await access(), { role: null });
  await request({ uid: "", role: "service_role", path: "/rpc/get_admin_access" });
  assert.deepEqual(await access(), { role: "admin", request_path: "/rpc/get_admin_access", request_method: "POST" });
});

test("검수 건 기본 정보 RPC는 등록 담당에게 5개 값만 주고, 테이블 직접 조회는 막힌다", async () => {
  await request({ uid: staff, path: "/rpc/admin_get_register_shipment" });
  const row = (await q("select public.admin_get_register_shipment(7) as s"))[0].s;
  assert.deepEqual(Object.keys(row).sort(), ["id", "pickup_date", "seller_name", "seller_phone", "status"]);
  assert.equal(row.seller_name, "김샘플");
  assert.equal(row.seller_phone, "010-****-0000", "등록 담당에게는 전화번호를 가린다");
  assert.equal((await q("select public.admin_get_register_shipment(999) as s"))[0].s, null);

  await request({ uid: superAdmin, path: "/rpc/admin_get_register_shipment" });
  assert.equal((await q("select public.admin_get_register_shipment(7) as s"))[0].s.seller_phone, "010-0000-0000", "관리자는 원본");

  await request({ uid: member, path: "/rpc/admin_get_register_shipment" });
  await assert.rejects(q("select public.admin_get_register_shipment(7)"), /Admin access required/);

  // 등록 담당이 REST로 shipments를 직접 읽으면 RLS가 0행으로 막는다
  await request({ uid: staff, method: "GET", path: "/shipments" });
  await db.exec("set role authenticated");
  try {
    assert.equal((await q("select count(*)::int as n from public.shipments"))[0].n, 0);
  } finally {
    await db.exec("reset role");
  }
});

test("사진 버킷: 등록 담당은 올리기와 자기 파일 삭제만, 다른 버킷·남의 파일은 불가", async () => {
  await request({ uid: staff, path: null }); // Storage 요청 — 경로 없음
  await db.exec("set role authenticated");
  try {
    await q("insert into storage.objects(bucket_id, name, owner_id) values ('product-covers', 'register/a.jpg', $1)", [staff]);
    await q("insert into storage.objects(bucket_id, name, owner_id) values ('inspection-images', 'register/b.jpg', $1)", [staff]);
    await assert.rejects(q("insert into storage.objects(bucket_id, name, owner_id) values ('site-promotions', 'x.jpg', $1)", [staff]));
    await assert.rejects(q("insert into storage.objects(bucket_id, name, owner_id) values ('admin-study-materials', '2028/x.pdf', $1)", [staff]));
  } finally {
    await db.exec("reset role");
  }
  await q("insert into storage.objects(bucket_id, name, owner_id) values ('product-covers', 'edit/admin.jpg', $1)", [superAdmin]);

  await db.exec("set role authenticated");
  try {
    const deleted = await q("delete from storage.objects where bucket_id = 'product-covers' returning name");
    assert.deepEqual(deleted.map((row) => row.name), ["register/a.jpg"], "자기가 올린 파일만 지워진다");
  } finally {
    await db.exec("reset role");
  }

  // 일반 회원은 여전히 올릴 수 없다
  await request({ uid: member, path: null });
  await db.exec("set role authenticated");
  try {
    await assert.rejects(q("insert into storage.objects(bucket_id, name, owner_id) values ('product-covers', 'm.jpg', $1)", [member]));
  } finally {
    await db.exec("reset role");
  }
});

test("등록 대상 목록: 등록 담당에게는 전화번호를 가리고 회원 식별자를 뺀다", async () => {
  const list = async (search = null) =>
    (await q("select public.admin_list_register_targets($1, 30, 0) as rows", [search]))[0].rows;

  await request({ uid: superAdmin, path: "/rpc/admin_list_register_targets" });
  const adminRows = await list();
  assert.deepEqual(adminRows.map((row) => row.seller_phone), ["010-1234-5678", "010-9999-0005", "01055556789"]);
  assert.equal(adminRows[0].user_id, member, "관리자는 기존 값 그대로");
  assert.equal((await list("1234")).length, 1, "관리자는 전화번호 일부로도 검색");
  assert.deepEqual((await list("나유찬")).map((row) => row.ref_id), [11, 13], "관리자 검색에는 끝난 건도 나온다");

  await request({ uid: staff, path: "/rpc/admin_list_register_targets" });
  const staffRows = await list();
  assert.deepEqual(staffRows.map((row) => row.seller_phone), ["010-****-5678", "010-****-0005", "010-****-6789"]);
  assert.deepEqual(staffRows.map((row) => row.is_member), [true, false, false]);
  for (const row of staffRows) {
    assert.equal("user_id" in row, false);
    assert.equal("member_name" in row, false);
    assert.equal(JSON.stringify(row).includes("1234"), false, "가운데 자리가 어디에도 남지 않는다");
  }
  assert.deepEqual((await list("나유찬")).map((row) => row.ref_id), [11], "이름 검색 — 검수가 끝난 건은 빠진다");
  assert.deepEqual(await list("박과거"), [], "끝난 직접입고 건도 빠진다");
  assert.deepEqual(await list("_"), [], "와일드카드로 목록을 훑을 수 없다");
  assert.deepEqual(await list("%"), [], "와일드카드로 목록을 훑을 수 없다");
  assert.deepEqual((await list("PU-2611-0006")).map((row) => row.ref_id), [12], "신청 번호 검색");
  assert.deepEqual((await list("5678")).map((row) => row.ref_id), [11], "끝 4자리 검색");
  assert.deepEqual((await list("0005")).map((row) => row.ref_id).sort(), [11, 12], "끝 4자리 또는 신청 번호");
  assert.deepEqual(await list("1234"), [], "가운데 자리로는 찾을 수 없다");
  assert.deepEqual(await list("01012345678"), [], "전체 번호로도 찾을 수 없다");

  await request({ uid: member, path: "/rpc/admin_list_register_targets" });
  await assert.rejects(list(), /Admin access required/);
});

test("책을 등록하면 등록자가 남고, 서버 등록은 남기지 않는다", async () => {
  await request({ uid: staff, path: "/rpc/admin_register_customer_inventory", email: "Staff@Example.com" });
  await q("insert into public.books(id, shipment_id, title) values (101, 7, '수학의 정석'), (102, 7, '개념원리')");
  await request({ uid: superAdmin, path: "/rpc/admin_register_customer_inventory", email: "owner@example.com" });
  await q("insert into public.books(id, shipment_id, title) values (103, 7, '쎈')");
  await request({ uid: "", role: "service_role", path: null });
  await q("insert into public.books(id, shipment_id, title) values (104, 7, '배치 등록')");

  const logs = await q("select book_id::int as book_id, registered_by, registered_by_email from public.book_registration_log order by book_id");
  assert.deepEqual(logs, [
    { book_id: 101, registered_by: staff, registered_by_email: "staff@example.com" },
    { book_id: 102, registered_by: staff, registered_by_email: "staff@example.com" },
    { book_id: 103, registered_by: superAdmin, registered_by_email: "owner@example.com" },
  ]);

  const stats = (await q("select public.admin_staff_registration_stats() as s"))[0].s;
  assert.equal(stats[staff].total, 2);
  assert.equal(stats[staff].today, 2);
  assert.ok(stats[staff].last_at);
  assert.equal(stats[superAdmin].total, 1);

  // 브라우저 역할은 기록을 직접 읽거나 고칠 수 없다
  for (const privilege of ["select", "insert", "update", "delete"]) {
    const ok = (await q("select has_table_privilege('authenticated', 'public.book_registration_log', $1) as ok", [privilege]))[0].ok;
    assert.equal(ok, false, privilege);
  }
});

test("역할 값은 정해진 것만 허용하고, 등록 담당에게 열지 않는 함수는 직접 실행 권한이 없다", async () => {
  await assert.rejects(q("insert into public.admin_users(email, user_id, role) values ('x@example.com', $1, 'root')", [member]));
  const acl = async (signature, role) =>
    (await q("select has_function_privilege($1, $2, 'execute') as ok", [role, signature]))[0].ok;
  assert.equal(await acl("public.intake_request_allowed()", "authenticated"), false);
  assert.equal(await acl("public.intake_request_allowed()", "anon"), false);
  assert.equal(await acl("public.get_admin_access()", "anon"), false);
  assert.equal(await acl("public.get_admin_access()", "authenticated"), true);
  assert.equal(await acl("public.is_intake_staff()", "anon"), false);
  assert.equal(await acl("public.admin_get_register_shipment(bigint)", "anon"), false);
  assert.equal(await acl("public.admin_list_register_targets(text, integer, integer)", "anon"), false);
  assert.equal(await acl("public.admin_list_register_targets(text, integer, integer)", "authenticated"), true);
  assert.equal(await acl("public.admin_staff_registration_stats()", "authenticated"), false);
  assert.equal(await acl("public.admin_staff_registration_stats()", "service_role"), true);
  assert.equal(await acl("public.mask_phone_for_intake(text)", "authenticated"), false);
});
