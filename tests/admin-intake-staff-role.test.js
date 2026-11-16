// 교재 등록 담당(role=intake) 권한 — 20261116030246_admin_intake_staff_role.sql
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
async function request({ uid = "", role = "authenticated", method = "POST", path = null }) {
  await q(
    "select set_config('app.uid',$1,false), set_config('app.role',$2,false), set_config('request.method',$3,false), set_config('request.path',$4,false)",
    [uid, role, path === null ? "" : method, path ?? ""],
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
  `);
  await db.exec(await readFile(new URL("../supabase/migrations/20261116030246_admin_intake_staff_role.sql", import.meta.url), "utf8"));
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
    "admin_recent_intake_targets", "admin_search_register_targets", "admin_start_inspection_from_pickup",
    "admin_get_register_shipment", "admin_search_products_for_register", "admin_intake_catalog_metadata",
    "admin_intake_price_context", "admin_suggest_register_price", "admin_suggest_book_type",
    "admin_get_register_sales_history", "admin_register_customer_inventory",
  ];
  for (const name of allowed) {
    await request({ uid: staff, path: `/rpc/${name}` });
    assert.equal(await isAdmin(), true, name);
  }
  await request({ uid: staff, path: "/rest/v1/rpc/admin_recent_intake_targets" });
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
    ["POST", "/rpc/admin_recent_intake_targets_extra"], // 이름이 비슷한 다른 함수
    ["POST", "/rpc/xadmin_recent_intake_targets"],
    ["GET", "/rpc/admin_recent_intake_targets"],       // 허용 RPC라도 POST만
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
  assert.equal((await q("select public.admin_get_register_shipment(999) as s"))[0].s, null);

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
});
