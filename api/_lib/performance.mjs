import { createSign, createHash } from "node:crypto";
import { getVercelOidcToken } from "@vercel/oidc";

const DAY_MS = 86_400_000;
const CACHE_MS = 15 * 60_000;
const cache = new Map();
const inFlight = new Map();
const tokenCache = new Map();
const number = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;
const ratio = (n, d, scale = 1) => d > 0 ? n / d * scale : null;
const shift = (date, days) => new Date(Date.parse(date) + days * DAY_MS).toISOString().slice(0, 10);

export function parsePerformanceQuery(query, now = new Date()) {
  const { from, to, level = "campaign", campaignId, adsetId } = query ?? {};
  const today = new Date(now.getTime() + 9 * 3_600_000).toISOString().slice(0, 10);
  for (const date of [from, to]) {
    if (typeof date !== "string" || !/^20\d{2}-\d{2}-\d{2}$/.test(date)
      || !Number.isFinite(Date.parse(date)) || new Date(date).toISOString().slice(0, 10) !== date) throw new Error("INVALID_RANGE");
  }
  const days = (Date.parse(to) - Date.parse(from)) / DAY_MS + 1;
  if (days < 1 || days > 366 || to > today) throw new Error("INVALID_RANGE");
  if (!["campaign", "adset", "ad"].includes(level)) throw new Error("INVALID_LEVEL");
  for (const id of [campaignId, adsetId]) if (id != null && (typeof id !== "string" || !/^\d{1,32}$/.test(id))) throw new Error("INVALID_ID");
  return { from, to, previousFrom: shift(from, -days), previousTo: shift(from, -1), level, campaignId, adsetId };
}

// 응답/예외의 원문에는 토큰, 계정 정보가 섞일 수 있어 클라이언트나 로그에 전달하지 않는다.
export async function fetchReportJson(url, options = {}, fetcher = fetch) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetcher(url, { ...options, redirect: "error", signal: AbortSignal.timeout(12_000) });
      const body = await response.json();
      if (response.ok && !body.error) return body;
      const retryable = response.status === 429 || response.status >= 500 || body.error?.is_transient === true;
      if (!retryable || attempt === 1) throw Object.assign(new Error("PROVIDER_REQUEST_FAILED"), { noRetry: true });
    } catch (error) {
      if (attempt === 1 || error.noRetry) throw new Error("PROVIDER_REQUEST_FAILED");
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("PROVIDER_REQUEST_FAILED");
}

function fingerprint(value) { return createHash("sha256").update(value).digest("hex"); }

function boundedFetcher(fetcher) {
  const deadline = Date.now() + 40_000;
  return (url, options) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("PROVIDER_DEADLINE");
    return fetcher(url, { ...options, signal: AbortSignal.any([options.signal, AbortSignal.timeout(remaining)]) });
  };
}

async function cached(key, loader) {
  const entry = cache.get(key);
  if (entry && Date.now() - entry.time < CACHE_MS) return entry.value;
  if (inFlight.has(key)) return inFlight.get(key);
  const pending = loader().then((value) => {
    if (cache.size >= 32) cache.delete(cache.keys().next().value);
    cache.set(key, { time: Date.now(), value });
    return value;
  }).finally(() => inFlight.delete(key));
  inFlight.set(key, pending);
  return pending;
}

async function googleAccessToken(raw, fetcher) {
  const key = fingerprint(raw);
  const prior = tokenCache.get(key);
  if (prior && prior.expires > Date.now() + 60_000) return prior.token;
  const account = JSON.parse(raw);
  if (account.type !== "service_account" || !account.client_email || !account.private_key) throw new Error("INVALID_SERVICE_ACCOUNT");
  const now = Math.floor(Date.now() / 1000);
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const input = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({ iss: account.client_email,
    scope: "https://www.googleapis.com/auth/analytics.readonly", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 })}`;
  const signature = createSign("RSA-SHA256").update(input).sign(account.private_key, "base64url");
  const response = await fetchReportJson("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${input}.${signature}` }).toString(),
  }, fetcher);
  if (!response.access_token) throw new Error("MISSING_GOOGLE_TOKEN");
  tokenCache.clear();
  tokenCache.set(key, { token: response.access_token, expires: Date.now() + number(response.expires_in) * 1000 });
  return response.access_token;
}

// 조직의 장기 키 발급 금지 정책을 유지한다. Google에서 production 주체를 검증한 뒤
// 이 서비스 계정의 analytics.readonly 토큰만 15분 동안 발급받는다.
export async function googleFederatedAccessToken(env, fetcher = fetch, getToken = getVercelOidcToken) {
  const audience = env.GA4_WIF_AUDIENCE;
  const email = env.GA4_SERVICE_ACCOUNT_EMAIL;
  if (!/^\/\/iam\.googleapis\.com\/projects\/\d+\/locations\/global\/workloadIdentityPools\/[a-z0-9-]+\/providers\/[a-z0-9-]+$/.test(audience ?? "")
    || !/^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$/.test(email ?? "")) throw new Error("INVALID_GA_FEDERATION_CONFIG");
  const key = `wif:${audience}:${email}`;
  const prior = tokenCache.get(key);
  if (prior && prior.expires > Date.now() + 60_000) return prior.token;
  let timer;
  const subjectToken = await Promise.race([
    Promise.resolve().then(getToken),
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("OIDC_TOKEN_TIMEOUT")), 8_000); }),
  ]).finally(() => clearTimeout(timer));
  if (typeof subjectToken !== "string" || !subjectToken) throw new Error("MISSING_OIDC_TOKEN");
  const federation = await fetchReportJson("https://sts.googleapis.com/v1/token", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ grantType: "urn:ietf:params:oauth:grant-type:token-exchange", audience,
      scope: "https://www.googleapis.com/auth/iam", requestedTokenType: "urn:ietf:params:oauth:token-type:access_token",
      subjectTokenType: "urn:ietf:params:oauth:token-type:jwt", subjectToken }),
  }, fetcher);
  if (!federation.access_token) throw new Error("MISSING_FEDERATED_TOKEN");
  const result = await fetchReportJson(`https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${email}:generateAccessToken`, {
    method: "POST", headers: { Authorization: `Bearer ${federation.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ scope: ["https://www.googleapis.com/auth/analytics.readonly"], lifetime: "900s" }),
  }, fetcher);
  const expires = Date.parse(result.expireTime);
  if (!result.accessToken || !Number.isFinite(expires) || expires <= Date.now()) throw new Error("INVALID_GOOGLE_TOKEN");
  tokenCache.clear();
  tokenCache.set(key, { token: result.accessToken, expires });
  return result.accessToken;
}

export function decodeGaRows(report) {
  if (!report || !Array.isArray(report.metricHeaders)) throw new Error("INVALID_GA_REPORT");
  return (report.rows ?? []).map((row) => {
    if (row.metricValues?.length !== report.metricHeaders.length || row.dimensionValues?.length !== (report.dimensionHeaders?.length ?? 0)
      || row.metricValues.some((item) => item.value == null || !Number.isFinite(Number(item.value)))) throw new Error("INVALID_GA_ROW");
    return Object.fromEntries([
    ...(report.dimensionHeaders ?? []).map((header, index) => [header.name, row.dimensionValues?.[index]?.value]),
    ...report.metricHeaders.map((header, index) => [header.name, number(row.metricValues?.[index]?.value)]),
    ]);
  });
}

export function decodeFunnel(report) {
  const rows = decodeGaRows(report.funnelTable);
  const first = rows.find((row) => /^1\. /.test(row.funnelStepName));
  const second = rows.find((row) => /^2\. /.test(row.funnelStepName));
  if (rows.length && !first) throw new Error("INVALID_FUNNEL_STEPS");
  const entered = first?.activeUsers ?? 0;
  const completed = second?.activeUsers ?? 0;
  return { entered, completed, rate: ratio(completed, entered, 100),
    sampled: (report.funnelTable.metadata?.samplingMetadatas?.length ?? 0) > 0 };
}

export async function loadGaPerformance(range, env = process.env, fetcher = fetch, getOidcToken = getVercelOidcToken) {
  const property = env.GA4_PROPERTY_ID;
  const credentials = env.GA4_SERVICE_ACCOUNT_JSON;
  const federated = Boolean(env.GA4_WIF_AUDIENCE && env.GA4_SERVICE_ACCOUNT_EMAIL);
  if (!property || (!credentials && !federated)) return { status: "not_configured", message: "GA4 조회 연결이 필요합니다." };
  if (!/^\d+$/.test(property)) throw new Error("INVALID_GA_PROPERTY");
  const scopedFetch = boundedFetcher(fetcher);
  const identity = federated ? `${env.GA4_WIF_AUDIENCE}:${env.GA4_SERVICE_ACCOUNT_EMAIL}` : fingerprint(credentials);
  return cached(`ga:${property}:${identity}:${range.from}:${range.to}`, async () => {
    const token = federated ? await googleFederatedAccessToken(env, scopedFetch, getOidcToken) : await googleAccessToken(credentials, scopedFetch);
    const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
    const periods = [
      { startDate: range.from, endDate: range.to, name: "current" },
      { startDate: range.previousFrom, endDate: range.previousTo, name: "previous" },
    ];
    const call = (version, method, body) => fetchReportJson(`https://analyticsdata.googleapis.com/${version}/properties/${property}:${method}`,
      { method: "POST", headers, body: JSON.stringify(body) }, scopedFetch);
    // 기간 방문자는 일별 방문자의 합이 아닌 별도 중복 제거 보고서로 조회한다.
    const metrics = ["totalUsers", "sessions", "ecommercePurchases", "sessionKeyEventRate:purchase"].map((name) => ({ name }));
    const core = await call("v1beta", "batchRunReports", { requests: [
      { dateRanges: periods, metrics, limit: "10" },
      { dateRanges: [periods[0]], metrics, dimensions: [{ name: "date" }], limit: "400", orderBys: [{ dimension: { dimensionName: "date" } }] },
    ] });
    const coreRows = decodeGaRows(core.reports?.[0]);
    if (coreRows.some((row) => !["current", "previous"].includes(row.dateRange))) throw new Error("INVALID_GA_PERIOD");
    if (core.reports.some((report) => report.metadata?.timeZone && report.metadata.timeZone !== "Asia/Seoul")) throw new Error("GA_TIMEZONE_MISMATCH");
    const mapSummary = (row = {}) => ({ visitors: row.totalUsers ?? 0, sessions: row.sessions ?? 0,
      purchases: row.ecommercePurchases ?? 0, cvr: row.sessions > 0 ? (row["sessionKeyEventRate:purchase"] ?? 0) * 100 : null });
    const result = { status: "ready", updatedAt: new Date().toISOString(),
      current: mapSummary(coreRows.find((row) => row.dateRange === "current")),
      previous: mapSummary(coreRows.find((row) => row.dateRange === "previous")),
      daily: decodeGaRows(core.reports?.[1]).map((row) => ({ ...mapSummary(row), date: `${row.date.slice(0, 4)}-${row.date.slice(4, 6)}-${row.date.slice(6, 8)}` })),
      thresholded: core.reports.some((report) => report.metadata?.subjectToThresholding || report.metadata?.dataLossFromOtherRow),
    };
    const pairs = [["view_item", "add_to_cart"], ["begin_checkout", "purchase"]];
    const funnels = await Promise.allSettled(periods.flatMap((period) => pairs.map((events) => call("v1alpha", "runFunnelReport", {
      dateRanges: [period], funnel: { isOpenFunnel: false, steps: events.map((eventName) => ({ name: eventName,
        filterExpression: { funnelEventFilter: { eventName } } })) },
    }).then(decodeFunnel))));
    for (const [index, period] of ["current", "previous"].entries()) {
      const cart = funnels[index * 2], checkout = funnels[index * 2 + 1];
      result[period].cartFunnel = cart.status === "fulfilled" ? cart.value : null;
      result[period].checkoutFunnel = checkout.status === "fulfilled" ? checkout.value : null;
      result[period].cartRate = result[period].cartFunnel?.rate ?? null;
      result[period].checkoutAbandonment = result[period].checkoutFunnel?.rate == null ? null : 100 - result[period].checkoutFunnel.rate;
    }
    result.funnelStatus = funnels.every((item) => item.status === "fulfilled") ? "ready" : "error";
    return result;
  });
}

export function metaPurchase(row) {
  // 여러 action_type은 같은 구매의 중복 표현이다. 합산하면 구매/ROAS가 부풀려진다.
  const types = ["purchase", "omni_purchase", "offsite_conversion.fb_pixel_purchase"];
  const type = types.find((candidate) => (row.actions ?? []).some((item) => item.action_type === candidate)
    || (row.action_values ?? []).some((item) => item.action_type === candidate));
  return { purchases: number(row.actions?.find((item) => item.action_type === type)?.value),
    revenue: number(row.action_values?.find((item) => item.action_type === type)?.value) };
}

export function summarizeMeta(rows) {
  const sum = rows.reduce((total, row) => {
    const purchase = metaPurchase(row);
    for (const key of ["spend", "impressions", "clicks"]) total[key] += number(row[key]);
    total.purchases += purchase.purchases;
    total.revenue += purchase.revenue;
    return total;
  }, { spend: 0, impressions: 0, clicks: 0, purchases: 0, revenue: 0 });
  return { ...sum, cpa: ratio(sum.spend, sum.purchases), roas: ratio(sum.revenue, sum.spend, 100),
    ctr: ratio(sum.clicks, sum.impressions, 100), cpc: ratio(sum.spend, sum.clicks) };
}

export async function loadMetaPerformance(range, env = process.env, fetcher = fetch) {
  const account = env.META_AD_ACCOUNT_ID?.replace(/^act_/, "");
  const token = env.META_ADS_ACCESS_TOKEN;
  if (!account || !token) return { status: "not_configured", message: "Meta 광고 조회 연결이 필요합니다." };
  const scopedFetch = boundedFetcher(fetcher);
  const version = env.META_GRAPH_API_VERSION || "v26.0";
  if (!/^\d+$/.test(account) || !/^v\d+\.0$/.test(version)) throw new Error("INVALID_META_CONFIG");
  const base = `https://graph.facebook.com/${version}/act_${account}`;
  const headers = { Authorization: `Bearer ${token}` };
  const identity = `${version}:${account}:${fingerprint(token)}`;
  const accountInfo = await cached(`meta-info:${identity}`, () => fetchReportJson(`${base}?fields=name,currency,timezone_name`, { headers }, scopedFetch));
  if (accountInfo.currency !== "KRW" || accountInfo.timezone_name !== "Asia/Seoul") throw new Error("META_TIMEZONE_CURRENCY_MISMATCH");
  async function insights(params) {
    const rows = [];
    let after;
    for (let page = 0; page < 20; page += 1) {
      const query = new URLSearchParams({ ...params, limit: "500", action_report_time: "conversion", use_unified_attribution_setting: "true" });
      if (after) query.set("after", after);
      // paging.next의 전체 URL(토큰 포함 가능)은 따라가지 않고 고정 호스트와 커서만 사용.
      const response = await fetchReportJson(`${base}/insights?${query}`, { headers }, scopedFetch);
      if (!Array.isArray(response.data)) throw new Error("INVALID_META_REPORT");
      rows.push(...response.data);
      if (!response.paging?.next) return rows;
      if (!response.paging?.cursors?.after || response.paging.cursors.after === after) throw new Error("INVALID_META_CURSOR");
      after = response.paging.cursors.after;
    }
    throw new Error("META_REPORT_TOO_LARGE");
  }
  const fields = "date_start,date_stop,spend,impressions,clicks,actions,action_values";
  const totals = await cached(`meta:${identity}:${range.from}:${range.to}`, async () => {
    const rows = await insights({ fields, level: "account", time_increment: "1", time_range: JSON.stringify({ since: range.previousFrom, until: range.to }) });
    const current = rows.filter((row) => row.date_start >= range.from && row.date_start <= range.to);
    return { status: "ready", account: { id: account, name: accountInfo.name || "" }, updatedAt: new Date().toISOString(), current: summarizeMeta(current),
      previous: summarizeMeta(rows.filter((row) => row.date_start < range.from && row.date_start >= range.previousFrom)),
      daily: current.map((row) => ({ date: row.date_start, ...summarizeMeta([row]) })) };
  });
  try {
    const breakdown = await cached(`meta-rows:${identity}:${JSON.stringify(range)}`, async () => {
      const filters = [];
      if (range.campaignId) filters.push({ field: "campaign.id", operator: "IN", value: [range.campaignId] });
      if (range.adsetId) filters.push({ field: "adset.id", operator: "IN", value: [range.adsetId] });
      const rows = await insights({ fields: `${fields},${range.level}_id,${range.level}_name`, level: range.level,
        time_range: JSON.stringify({ since: range.from, until: range.to }), ...(filters.length ? { filtering: JSON.stringify(filters) } : {}) });
      return rows.map((row) => ({ id: row[`${range.level}_id`], name: row[`${range.level}_name`], ...summarizeMeta([row]) })).sort((a, b) => b.spend - a.spend);
    });
    return { ...totals, breakdownStatus: "ready", breakdown };
  } catch {
    return { ...totals, breakdownStatus: "error", breakdown: [] };
  }
}

export async function optionalProvider(loader, name) {
  try { return await loader(); } catch (error) {
    return { status: "error", message: error.message === "META_TIMEZONE_CURRENCY_MISMATCH"
      ? "Meta 광고 계정의 통화(KRW)·시간대(서울)를 확인해주세요."
      : error.message === "GA_TIMEZONE_MISMATCH" ? "GA4 속성의 시간대가 서울인지 확인해주세요."
      : `${name} 데이터를 불러오지 못했습니다. 연결 권한과 토큰 상태를 확인해주세요.` };
  }
}
