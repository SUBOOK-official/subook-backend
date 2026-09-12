import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { parsePerformanceQuery, summarizeMeta, loadMetaPerformance, loadGaPerformance, decodeFunnel, fetchReportJson, googleFederatedAccessToken } from "../_lib/performance.js";
import { createPerformanceHandler } from "./performance.js";

const range = parsePerformanceQuery({ from: "2026-09-06", to: "2026-09-12" }, new Date("2026-09-12T10:00Z"));
const response = (data, status = 200) => ({ ok: status < 400, status, json: async () => data });

test("query validates KST, dates, max period, and drilldown injection", () => {
  assert.equal(range.previousFrom, "2026-08-30");
  assert.equal(range.previousTo, "2026-09-05");
  assert.throws(() => parsePerformanceQuery({ from: "2026-02-30", to: "2026-03-01" }));
  assert.throws(() => parsePerformanceQuery({ from: "2025-01-01", to: "2026-09-12" }));
  assert.throws(() => parsePerformanceQuery({ ...range, campaignId: "123&access_token=x" }));
  assert.throws(() => parsePerformanceQuery({ ...range, level: ["campaign"] }));
  assert.equal(parsePerformanceQuery({ from: "2026-09-12", to: "2026-09-12" }, new Date("2026-09-11T15:00:00Z")).from, "2026-09-12");
});

test("Meta totals never sum overlapping purchase types or average daily CPA/ROAS", () => {
  const total = summarizeMeta([
    { spend: "100", actions: [{ action_type: "purchase", value: "1" }, { action_type: "omni_purchase", value: "1" }], action_values: [{ action_type: "purchase", value: "200" }, { action_type: "omni_purchase", value: "200" }] },
    { spend: "900", actions: [{ action_type: "offsite_conversion.fb_pixel_purchase", value: "9" }], action_values: [{ action_type: "offsite_conversion.fb_pixel_purchase", value: "1800" }] },
  ]);
  assert.equal(total.purchases, 10); assert.equal(total.revenue, 2000);
  assert.equal(total.cpa, 100); assert.equal(total.roas, 200);
  assert.equal(summarizeMeta([]).cpa, null); assert.equal(summarizeMeta([]).roas, null);
});

test("Meta paginates via fixed host cursor; whole-account totals survive drilldown", async () => {
  const calls = [];
  const fetcher = async (input, options) => {
    const url = new URL(input); calls.push(url);
    assert.equal(url.origin, "https://graph.facebook.com");
    assert.equal(options.headers.Authorization, "Bearer test-pagination");
    assert.equal(url.searchParams.has("access_token"), false);
    if (url.pathname.endsWith("act_123")) return response({ currency: "KRW", timezone_name: "Asia/Seoul" });
    if (url.searchParams.get("level") === "account") {
      if (!url.searchParams.has("after")) return response({ data: [{ date_start: "2026-09-05", spend: "40" }], paging: { next: "https://evil.invalid/?token=secret", cursors: { after: "page-2" } } });
      return response({ data: [{ date_start: "2026-09-06", spend: "100" }] });
    }
    assert.deepEqual(JSON.parse(url.searchParams.get("filtering")), [{ field: "campaign.id", operator: "IN", value: ["55"] }]);
    return response({ data: [{ adset_id: "7", adset_name: "fixture", spend: "25" }] });
  };
  const result = await loadMetaPerformance({ ...range, level: "adset", campaignId: "55" }, { META_AD_ACCOUNT_ID: "123", META_ADS_ACCESS_TOKEN: "test-pagination" }, fetcher);
  assert.equal(result.current.spend, 100); assert.equal(result.previous.spend, 40);
  assert.equal(result.breakdown[0].spend, 25); assert.equal(calls.length, 4);
});

test("Meta currency mismatch fails instead of displaying USD as KRW", async () => {
  await assert.rejects(() => loadMetaPerformance(range, { META_AD_ACCOUNT_ID: "99", META_ADS_ACCESS_TOKEN: "usd" }, async () => response({ currency: "USD", timezone_name: "America/Los_Angeles" })), /MISMATCH/);
});

function gaReport(dimensions, metrics, rows) {
  return { dimensionHeaders: dimensions.map((name) => ({ name })), metricHeaders: metrics.map((name) => ({ name })),
    rows: rows.map(([dims, values]) => ({ dimensionValues: dims.map((value) => ({ value })), metricValues: values.map((value) => ({ value: String(value) })) })) };
}
const funnelFixture = { funnelTable: gaReport(["funnelStepName"], ["activeUsers"], [[["1. start"], [10]], [["2. finish"], [3]]]) };
test("funnel uses sequential same-cohort users and handles an empty funnel", () => {
  assert.deepEqual(decodeFunnel(funnelFixture), { entered: 10, completed: 3, rate: 30, sampled: false });
  assert.equal(decodeFunnel({ funnelTable: gaReport(["funnelStepName"], ["activeUsers"], []) }).rate, null);
});

test("GA period unique users are not summed from daily rows; one funnel failure preserves traffic", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const credentials = JSON.stringify({ type: "service_account", client_email: "fixture@example.invalid", private_key: privateKey.export({ type: "pkcs8", format: "pem" }) });
  const metrics = ["totalUsers", "sessions", "ecommercePurchases", "sessionKeyEventRate:purchase"];
  const result = await loadGaPerformance(range, { GA4_PROPERTY_ID: "1234", GA4_SERVICE_ACCOUNT_JSON: credentials }, async (url, options) => {
    if (url.includes("oauth2")) return response({ access_token: "fixture-google", expires_in: 3600 });
    assert.equal(options.headers.Authorization, "Bearer fixture-google");
    const body = JSON.parse(options.body);
    if (url.endsWith("batchRunReports")) return response({ reports: [
      gaReport(["dateRange"], metrics, [[["current"], [10, 20, 2, 0.1]], [["previous"], [8, 15, 1, 0.05]]]),
      gaReport(["date"], metrics, [[["20260906"], [8, 10, 1, 0.1]], [["20260907"], [7, 10, 1, 0.1]]]),
    ] });
    if (body.funnel.steps[0].name === "begin_checkout") return response({ error: {} }, 403);
    assert.equal(body.funnel.isOpenFunnel, false);
    return response(funnelFixture);
  });
  assert.equal(result.current.visitors, 10); assert.equal(result.daily.reduce((sum, row) => sum + row.visitors, 0), 15);
  assert.equal(result.current.cvr, 10); assert.equal(result.current.cartRate, 30);
  assert.equal(result.current.checkoutAbandonment, null); assert.equal(result.funnelStatus, "error");
});

test("unconfigured integrations issue no external requests", async () => {
  const never = () => { throw new Error("must not fetch"); };
  assert.equal((await loadGaPerformance(range, {}, never)).status, "not_configured");
  assert.equal((await loadMetaPerformance(range, {}, never)).status, "not_configured");
});

test("keyless GA auth exchanges only with Google, scopes analytics read-only, and caches short-lived tokens", async () => {
  const env = { GA4_WIF_AUDIENCE: "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/test/providers/vercel",
    GA4_SERVICE_ACCOUNT_EMAIL: "reader@test-project.iam.gserviceaccount.com" };
  let calls = 0;
  const fetcher = async (url, options) => {
    calls += 1;
    const body = JSON.parse(options.body);
    if (url === "https://sts.googleapis.com/v1/token") {
      assert.equal(options.headers.Authorization, undefined);
      assert.equal(body.audience, env.GA4_WIF_AUDIENCE);
      assert.equal(body.subjectToken, "test-vercel-token");
      assert.equal(body.scope, "https://www.googleapis.com/auth/iam");
      return response({ access_token: "test-federated" });
    }
    assert.equal(url, "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/reader@test-project.iam.gserviceaccount.com:generateAccessToken");
    assert.equal(options.headers.Authorization, "Bearer test-federated");
    assert.deepEqual(body, { scope: ["https://www.googleapis.com/auth/analytics.readonly"], lifetime: "900s" });
    return response({ accessToken: "test-analytics", expireTime: new Date(Date.now() + 900_000).toISOString() });
  };
  assert.equal(await googleFederatedAccessToken(env, fetcher, async () => "test-vercel-token"), "test-analytics");
  assert.equal(await googleFederatedAccessToken(env, fetcher, async () => { throw new Error("cached token expected"); }), "test-analytics");
  assert.equal(calls, 2);
  await assert.rejects(() => googleFederatedAccessToken({ ...env, GA4_WIF_AUDIENCE: "//evil.invalid/path" }, fetcher), /INVALID_GA_FEDERATION_CONFIG/);
  assert.equal(calls, 2);
});

test("keyless GA auth rejects missing identity and invalid token expiry", async () => {
  const env = { GA4_WIF_AUDIENCE: "//iam.googleapis.com/projects/456/locations/global/workloadIdentityPools/test/providers/vercel",
    GA4_SERVICE_ACCOUNT_EMAIL: "reader@test-project.iam.gserviceaccount.com" };
  await assert.rejects(() => googleFederatedAccessToken(env, () => { throw new Error("must not fetch"); }, async () => ""), /MISSING_OIDC_TOKEN/);
  await assert.rejects(() => googleFederatedAccessToken(env, async (url) => response(url.includes("sts.") ? { access_token: "temporary" } : { accessToken: "expired", expireTime: "2000-01-01T00:00:00Z" }), async () => "vercel-test"), /INVALID_GOOGLE_TOKEN/);
});

test("external read retries transient errors but not authorization failures", async () => {
  let calls = 0;
  assert.deepEqual(await fetchReportJson("https://fixture.invalid", {}, async () => ++calls === 1 ? response({ error: {} }, 503) : response({ ok: true })), { ok: true });
  assert.equal(calls, 2); calls = 0;
  await assert.rejects(() => fetchReportJson("https://fixture.invalid", {}, async () => { calls += 1; return response({ error: "secret" }, 401); }), /PROVIDER_REQUEST_FAILED/);
  assert.equal(calls, 1);
});

function mockRes() { return { headers: {}, statusCode: 200, setHeader(key, value) { this.headers[key] = value; }, status(code) { this.statusCode = code; return this; }, json(data) { this.body = data; return this; } }; }
test("API denies anonymous/non-admin before provider calls and sanitizes failures", async () => {
  let calls = 0;
  const handler = createPerformanceHandler({ checkAdmin: async () => { throw Object.assign(new Error("private"), { status: 403 }); }, loadGa: async () => { calls += 1; } });
  let res = mockRes();
  await handler({ method: "GET", headers: {}, query: range }, res); assert.equal(res.statusCode, 401);
  res = mockRes(); await handler({ method: "GET", headers: { authorization: "Bearer test" }, query: range }, res);
  assert.equal(res.statusCode, 403); assert.equal(calls, 0); assert.ok(!JSON.stringify(res.body).includes("private"));
  const partial = createPerformanceHandler({ checkAdmin: async () => {}, loadGa: async () => { throw new Error("secret-token"); }, loadMeta: async () => ({ status: "ready" }) });
  res = mockRes(); await partial({ method: "GET", headers: { authorization: "Bearer test" }, query: range }, res);
  assert.equal(res.body.ga.status, "error"); assert.equal(res.body.meta.status, "ready");
  assert.ok(!JSON.stringify(res.body).includes("secret-token")); assert.equal(res.headers["Cache-Control"], "private, no-store");
});

test("deployed copies match the backend sources", { skip: !existsSync(new URL("../../../frontend/apps/admin-web/api", import.meta.url)) }, () => {
  for (const file of ["admin/performance.js", "_lib/performance.js"]) {
    assert.equal(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"), readFileSync(new URL(`../../../frontend/apps/admin-web/api/${file}`, import.meta.url), "utf8"));
  }
});
