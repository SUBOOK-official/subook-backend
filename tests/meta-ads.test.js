import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";
import {
  validateMutation,
  prepareMutation,
  createMetaGraph,
  fingerprint,
  problem,
  landingUrl,
} from "../api/_lib/metaAds.js";
import { createMetaAdsHandler } from "../api/admin/meta-ads.js";

const env = {
  META_AD_ACCOUNT_ID: "123",
  META_ADS_ACCESS_TOKEN: "read-secret",
  META_ADS_MANAGEMENT_TOKEN: "write-secret",
  NODE_ENV: "production",
  VERCEL_ENV: "production",
};
const actor = "00000000-0000-4000-8000-000000000001";
const campaign = {
  id: "10",
  account_id: "123",
  name: "수북 구매",
  objective: "OUTCOME_SALES",
  status: "PAUSED",
  daily_budget: "30000",
  special_ad_categories: [],
  version: "current-version",
};
const edit = {
  action: "update",
  kind: "campaign",
  id: "10",
  version: campaign.version,
  values: { budgetType: "daily", budget: "50000" },
};
function fixture(options = {}) {
  const records = new Map();
  const writes = [];
  let deny = false;
  const graph = {
    config: { account: "123" },
    owned: async (kind, id) => ({
      ...campaign,
      ...options.entity,
      id,
      ...(options.version ? { version: options.version } : {}),
    }),
    list: async () => ({ rows: [], after: null }),
    request: async (path, params, method) => {
      if (method === "POST") {
        writes.push({ path, params });
        if (options.error) throw options.error;
        return options.result || { success: true };
      }
      if (path === "me/permissions")
        return {
          data: [
            {
              permission: options.permission || "ads_management",
              status: "granted",
            },
          ],
        };
      return {
        account_id: "123",
        currency: "KRW",
        timezone_name: "Asia/Seoul",
        user_tasks: ["ADVERTISE"],
      };
    },
  };
  const store = {
    rateLimit: async () => {},
    create: async (row) => {
      const record = {
        ...row,
        state: "prepared",
        expires_at: new Date(Date.now() + 600000).toISOString(),
      };
      records.set(row.id, record);
      return {
        id: row.id,
        review: row.review,
        state: record.state,
        expires_at: record.expires_at,
      };
    },
    get: async (id) => records.get(id),
    claim: async (id) => {
      const record = records.get(id);
      if (record.state !== "prepared") return null;
      record.state = "executing";
      return { id };
    },
    finish: async (id, state, result) => {
      if (options.failFinish) throw new Error("db unavailable");
      Object.assign(records.get(id), { state, result, payload: null });
    },
    saveDraft: async (draft) => draft,
  };
  const handler = createMetaAdsHandler({
    env: { ...env, ...options.env },
    authorize: async () => {
      if (deny) throw problem("관리자 권한 필요", 403);
      return { id: actor };
    },
    makeGraph: () => graph,
    makeStore: () => store,
  });
  const call = async (body, query = {}, headers = {}) => {
    const response = {
      code: 200,
      setHeader() {},
      status(code) {
        this.code = code;
        return this;
      },
      json(data) {
        this.body = data;
        return this;
      },
    };
    await handler(
      {
        method: body ? "POST" : "GET",
        headers: {
          authorization: "Bearer admin-session",
          "content-type": "application/json",
          origin: "https://admin.subook.kr",
          ...headers,
        },
        query,
        body,
      },
      response,
    );
    return response;
  };
  return {
    call,
    records,
    writes,
    graph,
    deny: () => {
      deny = true;
    },
  };
}
test("KRW 금액 유지, 새 광고와 복사본은 반드시 PAUSED", () => {
  assert.equal(validateMutation(edit).params.daily_budget, "50000");
  assert.equal(
    validateMutation({
      action: "create",
      kind: "campaign",
      values: { name: "새 광고", objective: "OUTCOME_SALES" },
    }).params.status,
    "PAUSED",
  );
  assert.equal(
    validateMutation({
      action: "copy",
      kind: "ad",
      id: "10",
      values: { suffix: " 복사" },
    }).params.status_option,
    "PAUSED",
  );
  for (const bad of ["-1", "1.5", "NaN", "1000000001"])
    assert.throws(() =>
      validateMutation({
        ...edit,
        values: { budgetType: "daily", budget: bad },
      }),
    );
});
test("임의 경로·지원하지 않는 필드·외부 도착 주소 차단", () => {
  assert.throws(() =>
    validateMutation({ ...edit, values: { access_token: "bad" } }),
  );
  assert.throws(() => validateMutation({ ...edit, kind: "__proto__" }));
  assert.throws(() => validateMutation({ ...edit, id: "../me" }));
  assert.throws(() => landingUrl("https://example.com/"));
  assert.throws(() => landingUrl("https://subook.kr/admin"));
  assert.equal(
    landingUrl("https://subook.kr/store?utm_campaign=old&subject=math"),
    "https://subook.kr/store?subject=math",
  );
});
test("단위가 맞지 않는 일일·총예산 전환 및 검토 버전 불일치 차단", async () => {
  const { graph } = fixture();
  await assert.rejects(
    prepareMutation(graph, { ...edit, version: "old" }),
    /변경/,
  );
  await assert.rejects(
    prepareMutation(graph, {
      ...edit,
      values: { budgetType: "lifetime", budget: 100000 },
    }),
    /방식/,
  );
});
test("연결 계정 밖 객체 차단 및 토큰은 URL에 포함하지 않음", async () => {
  const graph = createMetaGraph(
    { account: "123", version: "v26.0", token: "private-token" },
    async (url, options) => {
      assert.ok(!url.includes("private-token"));
      assert.equal(options.headers.Authorization, "Bearer private-token");
      return new Response(JSON.stringify({ id: "10", account_id: "999" }), {
        status: 200,
      });
    },
  );
  await assert.rejects(graph.owned("campaign", "10"), /연결된 광고 계정/);
  await assert.rejects(graph.request("https://evil.test"), /경로/);
});
test("Graph POST는 응답 유실 시 재시도하지 않고 결과 불명 처리", async () => {
  let calls = 0;
  const graph = createMetaGraph(
    { account: "123", version: "v26.0", token: "secret" },
    async () => {
      calls++;
      throw new Error("network");
    },
  );
  await assert.rejects(
    graph.request("10", { status: "PAUSED" }, "POST"),
    (e) => e.uncertain === true,
  );
  assert.equal(calls, 1);
});
test("비관리자·무인증·다른 출처 요청 차단", async () => {
  const f = fixture();
  assert.equal((await f.call(null, {}, { authorization: "" })).code, 401);
  assert.equal(
    (
      await f.call(
        { action: "prepare", operation: edit },
        {},
        { origin: "https://evil.test" },
      )
    ).code,
    403,
  );
  f.deny();
  assert.equal((await f.call(null)).code, 403);
  assert.equal(f.writes.length, 0);
});
test("조회 토큰만 있거나 preview이면 외부 변경 불가, 초안은 저장 가능", async () => {
  for (const options of [
    { env: { META_ADS_MANAGEMENT_TOKEN: "" } },
    { env: { VERCEL_ENV: "preview" } },
    { permission: "ads_read" },
  ]) {
    const f = fixture(options);
    assert.equal((await f.call(null)).body.canManage, false);
    assert.ok(
      (await f.call({ action: "prepare", operation: edit })).code >= 400,
    );
    assert.equal(
      (
        await f.call({
          action: "saveDraft",
          draft: { kind: "campaign", title: "초안", payload: { name: "초안" } },
        })
      ).code,
      200,
    );
    assert.equal(f.writes.length, 0);
  }
});
test("검토 후 명시 확인 필요, 성공 작업 재호출은 외부 변경 1회", async () => {
  const f = fixture();
  const plan = (await f.call({ action: "prepare", operation: edit })).body;
  assert.equal(f.writes.length, 0);
  assert.equal((await f.call({ action: "execute", id: plan.id })).code, 400);
  assert.equal(
    (await f.call({ action: "execute", id: plan.id, confirmed: true })).body
      .state,
    "succeeded",
  );
  assert.equal(
    (await f.call({ action: "execute", id: plan.id, confirmed: true })).body
      .repeated,
    true,
  );
  assert.equal(f.writes.length, 1);
  assert.equal(f.records.get(plan.id).payload, null);
});
test("동시 클릭·중복 실행은 한 번만 반영", async () => {
  const f = fixture();
  const plan = (await f.call({ action: "prepare", operation: edit })).body;
  const results = await Promise.all([
    f.call({ action: "execute", id: plan.id, confirmed: true }),
    f.call({ action: "execute", id: plan.id, confirmed: true }),
  ]);
  assert.ok(results.some((r) => r.code === 200));
  assert.equal(f.writes.length, 1);
});
test("다른 관리자·다른 계정·만료·내용 변조는 반영하지 않음", async () => {
  for (const mutation of [
    { actor_id: "another" },
    { account_id: "999" },
    { expires_at: "2020-01-01" },
    { request_hash: "changed" },
  ]) {
    const f = fixture();
    const plan = (await f.call({ action: "prepare", operation: edit })).body;
    Object.assign(f.records.get(plan.id), mutation);
    assert.ok(
      (await f.call({ action: "execute", id: plan.id, confirmed: true }))
        .code >= 400,
    );
    assert.equal(f.writes.length, 0);
  }
});
test("검토 이후 외부에서 변경되면 실행 중 잠금 후에도 버전 재확인", async () => {
  const f = fixture();
  const plan = (await f.call({ action: "prepare", operation: edit })).body;
  f.graph.owned = async () => ({ ...campaign, version: "changed" });
  assert.equal(
    (await f.call({ action: "execute", id: plan.id, confirmed: true })).code,
    409,
  );
  assert.equal(f.records.get(plan.id).state, "failed");
  assert.equal(f.writes.length, 0);
});
test("불명확 응답·네트워크 실패·이력 저장 실패 후 재시도 차단", async () => {
  for (const options of [
    { result: {} },
    { error: problem("응답 유실", 502, { uncertain: true }) },
    { failFinish: true },
  ]) {
    const f = fixture(options);
    const plan = (await f.call({ action: "prepare", operation: edit })).body;
    const result = await f.call({
      action: "execute",
      id: plan.id,
      confirmed: true,
    });
    assert.equal(result.body.state, "unknown");
    assert.equal(
      (await f.call({ action: "execute", id: plan.id, confirmed: true })).code,
      409,
    );
    assert.equal(f.writes.length, 1);
  }
});
test("자산을 연결 계정 목록으로 검증하며 상세 타겟은 보존", async () => {
  const { graph } = fixture();
  graph.owned = async (kind) =>
    kind === "campaign"
      ? campaign
      : {
          ...campaign,
          campaign_id: "10",
          targeting: {
            age_min: 20,
            age_max: 60,
            flexible_spec: [{ interests: [{ id: "99" }] }],
            geo_locations: { cities: [{ key: "1" }] },
            publisher_platforms: ["instagram"],
            instagram_positions: ["stream"],
          },
        };
  const op = await prepareMutation(graph, {
    action: "update",
    kind: "adset",
    id: "20",
    version: campaign.version,
    values: { targeting: { age_min: 25, age_max: 60 } },
  });
  assert.equal(op.params.targeting.flexible_spec[0].interests[0].id, "99");
  assert.deepEqual(op.params.targeting.instagram_positions, ["stream"]);
  await assert.rejects(
    prepareMutation(graph, {
      action: "update",
      kind: "adset",
      id: "20",
      version: campaign.version,
      values: { targeting: { custom_audiences: ["999"] } },
    }),
    /자산/,
  );
});
test("이미지 파일 형식 검증, 광고 본문 줄바꿈 허용", () => {
  assert.throws(
    () =>
      validateMutation({
        action: "image",
        kind: "creative",
        values: {
          bytes: Buffer.from("<svg/>").toString("base64"),
          name: "fake.png",
        },
      }),
    /PNG/,
  );
  const op = validateMutation({
    action: "create",
    kind: "creative",
    values: {
      name: "소재",
      format: "image",
      page_id: "11",
      image_hash: "a".repeat(32),
      link: "https://subook.kr/store",
      message: "수북\n교재",
      title: "교재",
      cta: "SHOP_NOW",
      tracking: {
        source: "instagram",
        medium: "cpc",
        campaign: "202610_sales",
        id: "123",
        content: "a",
      },
    },
  });
  assert.equal(op.params.object_story_spec.link_data.message, "수북\n교재");
});
test("DB RLS·권한·동일 광고 동시 쓰기 잠금 및 초안 버전 충돌", async () => {
  const db = new PGlite();
  try {
    await db.exec(
      `create role anon; create role authenticated; create role service_role bypassrls; create schema auth; create table auth.users(id uuid primary key); insert into auth.users values('${actor}');`,
    );
    await db.exec(
      readFileSync(
        new URL(
          "../supabase/migrations/20260930092122_admin_external_operations.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const rls = await db.query(
      "select relrowsecurity from pg_class where relname in ('admin_external_drafts','admin_external_actions')",
    );
    assert.ok(rls.rows.every((r) => r.relrowsecurity));
    for (const role of ["anon", "authenticated"]) {
      await db.exec(`set role ${role}`);
      await assert.rejects(
        db.query("select * from admin_external_actions"),
        /permission denied/,
      );
      await assert.rejects(
        db.query("select * from admin_external_drafts"),
        /permission denied/,
      );
      await db.exec("reset role");
    }
    await db.exec("set role service_role");
    const draft = (
      await db.query(
        `insert into admin_external_drafts(provider,kind,title,payload,created_by,updated_by) values('meta','campaign','초안','{}','${actor}','${actor}') returning id`,
      )
    ).rows[0];
    assert.equal(
      (
        await db.query(
          "update admin_external_drafts set version=2 where id=$1 and version=1 returning id",
          [draft.id],
        )
      ).rows.length,
      1,
    );
    assert.equal(
      (
        await db.query(
          "update admin_external_drafts set version=2 where id=$1 and version=1 returning id",
          [draft.id],
        )
      ).rows.length,
      0,
    );
    const sql = `insert into admin_external_actions(id,provider,account_id,actor_id,action,kind,object_id,request_hash,review,state) values(gen_random_uuid(),'meta','123','${actor}','status','campaign','10','hash','{}','executing')`;
    await db.query(sql);
    await assert.rejects(db.query(sql), /unique/);
    await db.query("update admin_external_actions set state='succeeded'");
    await db.query(sql);
  } finally {
    await db.close();
  }
});
test("변경 검토 해시는 키 순서에 무관하며 값 변경은 탐지", () => {
  assert.equal(fingerprint({ a: 1, b: 2 }), fingerprint({ b: 2, a: 1 }));
  assert.notEqual(fingerprint({ a: 1 }), fingerprint({ a: 2 }));
});

test("하위 목록은 검증한 부모 객체의 edge로 조회", async () => {
  const f = fixture(); let called;
  f.graph.list = async (path, params) => { called = { path, params }; return { rows: [], after: null }; };
  assert.equal((await f.call(null, { view: 'list', kind: 'adset', parentId: '10' })).code, 200);
  assert.equal(called.path, '10/adsets'); assert.equal(called.params.filtering, undefined);
});

test("광고 미리보기 HTML과 토큰 포함 URL은 관리자에게 전달하지 않음", async () => {
  for (const source of ['https://evil.test/frame', 'https://www.facebook.com/frame?access_token=secret']) {
    const f = fixture(); const request = f.graph.request;
    f.graph.request = async (path, params, method) => path.endsWith('/previews') ? { data: [{ body: `<iframe src="${source}"></iframe><script>alert(1)</script>` }] } : request(path, params, method);
    const result = await f.call(null, { view: 'preview', id: '10' });
    assert.equal(result.code, 502); assert.ok(!JSON.stringify(result.body).includes('secret'));
  }
});
