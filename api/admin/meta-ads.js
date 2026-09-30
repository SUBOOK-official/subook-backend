import { randomUUID } from "node:crypto";
import {
  loadMetaPerformance,
  parsePerformanceQuery,
} from "../_lib/performance.js";
import { authorizeAdmin, externalStore } from "../_lib/adminExternalStore.js";
import {
  META_ENTITY,
  META_ASSETS,
  metaConfig,
  createMetaGraph,
  connection,
  prepareMutation,
  fingerprint,
  scrub,
  entityKind,
  metaId,
  problem,
} from "../_lib/metaAds.js";

const uuid = (value) =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
const cursor = (value) => {
  if (
    value != null &&
    (typeof value !== "string" ||
      value.length > 2000 ||
      !/^[a-zA-Z0-9_=+\/-]+$/.test(value))
  )
    throw problem("목록 위치를 확인해 주세요.");
  return value;
};
function draftInput(input) {
  if (
    !input ||
    typeof input !== "object" ||
    !input.payload ||
    typeof input.payload !== "object" ||
    Array.isArray(input.payload)
  )
    throw problem("초안 내용을 확인해 주세요.");
  entityKind(input.kind);
  if (
    typeof input.title !== "string" ||
    !input.title.trim() ||
    input.title.length > 200 ||
    JSON.stringify(input.payload).length > 20000 ||
    /"(?:access_token|token|secret|bytes|authorization)"\s*:/i.test(
      JSON.stringify(input.payload),
    )
  )
    throw problem(
      "초안에는 광고 설정만 저장할 수 있습니다. 파일·인증정보는 제외해 주세요.",
    );
  if (input.id && (!uuid(input.id) || !Number.isInteger(input.version)))
    throw problem("초안을 다시 선택해 주세요.");
  return {
    id: input.id || null,
    version: input.version,
    kind: input.kind,
    title: input.title.trim(),
    payload: input.payload,
  };
}
function summaryResult(data) {
  const result = {};
  for (const key of [
    "id",
    "success",
    "copied_campaign_id",
    "copied_adset_id",
    "copied_ad_id",
    "ad_object_ids",
    "images",
  ])
    if (data[key] != null) result[key] = scrub(data[key]);
  return result;
}
export function createMetaAdsHandler({
  env = process.env,
  authorize = authorizeAdmin,
  makeGraph = createMetaGraph,
  makeStore = externalStore,
} = {}) {
  return async (req, res) => {
    res.setHeader("Cache-Control", "private, no-store");
    if (!["GET", "POST"].includes(req.method)) {
      res.setHeader("Allow", "GET, POST");
      return res
        .status(405)
        .json({ error: "허용하지 않은 요청입니다.", code: 405 });
    }
    const token = String(req.headers.authorization || "").match(
      /^Bearer\s+(\S+)$/i,
    )?.[1];
    if (!token)
      return res.status(401).json({ error: "로그인이 필요합니다.", code: 401 });
    try {
      const actor = await authorize(token, env);
      const query = req.query || {};
      if (req.method === "POST") {
        if (
          !String(req.headers["content-type"] || "").startsWith(
            "application/json",
          )
        )
          throw problem("JSON 요청이 필요합니다.", 415);
        const origin = req.headers.origin;
        const allowed = [
          "https://admin.subook.kr",
          ...(env.VERCEL_URL ? [`https://${env.VERCEL_URL}`] : []),
        ];
        if (
          origin &&
          !allowed.includes(origin) &&
          !(
            env.NODE_ENV !== "production" &&
            /^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin)
          )
        )
          throw problem("관리자 화면에서 다시 요청해 주세요.", 403);
        if (
          !req.body ||
          typeof req.body !== "object" ||
          Array.isArray(req.body) ||
          JSON.stringify(req.body).length > 4_150_000
        )
          throw problem("요청 크기 또는 형식을 확인해 주세요.", 413);
      }
      if (req.method === "GET" && query.view === "drafts")
        return res.status(200).json({ rows: await makeStore(env).drafts() });
      if (
        req.method === "POST" &&
        ["saveDraft", "archiveDraft"].includes(req.body.action)
      ) {
        const store = makeStore(env);
        if (req.body.action === "saveDraft")
          return res
            .status(200)
            .json(await store.saveDraft(draftInput(req.body.draft), actor.id));
        if (!uuid(req.body.id) || !Number.isInteger(req.body.version))
          throw problem("초안을 다시 선택해 주세요.");
        return res
          .status(200)
          .json(await store.archiveDraft(req.body.id, req.body.version));
      }
      const config = metaConfig(env);
      const graph = makeGraph(config);
      if (req.method === "GET") {
        const view = query.view || "connection";
        if (view === "insights") {
          let range;
          try {
            range = parsePerformanceQuery(query);
          } catch {
            throw problem("성과 기간은 오늘까지 1~366일 범위로 선택해 주세요.");
          }
          return res
            .status(200)
            .json(
              await loadMetaPerformance(range, {
                ...env,
                META_ADS_ACCESS_TOKEN: config.token,
              }),
            );
        }
        if (view === "connection") {
          const result = await connection(graph);
          return res
            .status(200)
            .json({
              ...result,
              canManage:
                result.canManage &&
                Boolean(env.META_ADS_MANAGEMENT_TOKEN) &&
                env.VERCEL_ENV !== "preview",
              managementConfigured: Boolean(env.META_ADS_MANAGEMENT_TOKEN),
              updatedAt: new Date().toISOString(),
            });
        }
        if (view === "history")
          return res
            .status(200)
            .json({ rows: await makeStore(env).history(config.account) });
        if (view === "detail")
          return res
            .status(200)
            .json(await graph.owned(entityKind(query.kind), metaId(query.id)));
        if (view === "list") {
          const kind = entityKind(query.kind || "campaign");
          const params = {
            fields: META_ENTITY[kind].fields,
            after: cursor(query.after),
          };
          let parentNode = `act_${config.account}`;
          if (query.parentId) {
            const parentKind =
              kind === "adset" ? "campaign" : kind === "ad" ? "adset" : null;
            if (!parentKind) throw problem("상위 광고 선택을 확인해 주세요.");
            await graph.owned(parentKind, metaId(query.parentId));
            parentNode = query.parentId;
          }
          if (query.status) {
            if (
              ![
                "ACTIVE",
                "PAUSED",
                "ARCHIVED",
                "DELETED",
                "DISAPPROVED",
                "PENDING_REVIEW",
                "CAMPAIGN_PAUSED",
                "ADSET_PAUSED",
              ].includes(query.status)
            )
              throw problem("상태를 확인해 주세요.");
            if (kind === "creative")
              throw problem("소재에는 게재 상태 필터가 없습니다.");
            params.effective_status = [query.status];
          }
          const result = await graph.list(
            `${parentNode}/${META_ENTITY[kind].edge}`,
            params,
          );
          return res
            .status(200)
            .json({
              ...result,
              rows: result.rows.map((row) => ({
                ...row,
                version: fingerprint(row),
              })),
            });
        }
        if (view === "assets") {
          const spec = Object.hasOwn(META_ASSETS, query.kind)
            ? META_ASSETS[query.kind]
            : null;
          if (!spec) throw problem("소재 목록 종류를 확인해 주세요.");
          return res
            .status(200)
            .json(
              await graph.list(`act_${config.account}/${spec.edge}`, {
                fields: spec.fields,
                after: cursor(query.after),
              }),
            );
        }
        if (view === "preview") {
          const id = metaId(query.id);
          await graph.owned("ad", id);
          const format = query.format || "MOBILE_FEED_STANDARD";
          if (
            ![
              "MOBILE_FEED_STANDARD",
              "DESKTOP_FEED_STANDARD",
              "INSTAGRAM_STANDARD",
              "INSTAGRAM_STORY",
              "INSTAGRAM_REELS",
            ].includes(format)
          )
            throw problem("미리보기 위치를 확인해 주세요.");
          const data = await graph.request(`${id}/previews`, {
            ad_format: format,
          });
          // Meta의 iframe 주소만 반환한다. 외부 HTML을 관리자 DOM에 삽입하지 않는다.
          const body = data.data?.[0]?.body || "";
          const match = body.match(/<iframe\b[^>]*\bsrc=["']([^"']+)["']/i);
          let url;
          try {
            url = new URL(match?.[1]?.replaceAll("&amp;", "&"));
          } catch {
            throw problem(
              "해당 게재 위치의 미리보기를 제공하지 않습니다.",
              422,
            );
          }
          if (
            url.protocol !== "https:" ||
            !/(^|\.)facebook\.com$/.test(url.hostname) ||
            url.username ||
            url.password ||
            [...url.searchParams.keys()].some((key) =>
              /token|secret/i.test(key),
            )
          )
            throw problem("미리보기 응답을 확인하지 못했습니다.", 502);
          return res.status(200).json({ url: url.href });
        }
        throw problem("요청한 기능을 찾지 못했습니다.", 404);
      }
      if (env.VERCEL_ENV === "preview")
        throw problem(
          "미리보기 배포에서는 실제 광고를 변경하지 않습니다.",
          403,
        );
      const writeGraph = makeGraph(metaConfig(env, true));
      const access = await connection(writeGraph);
      if (!access.canManage)
        throw problem(
          "Meta 광고 관리 권한과 광고 계정의 광고 만들기 권한을 확인해 주세요.",
          403,
        );
      const store = makeStore(env);
      if (req.body.action === "prepare") {
        await store.rateLimit(actor.id);
        const plan = await prepareMutation(writeGraph, req.body.operation);
        const record = await store.create({
          id: randomUUID(),
          provider: "meta",
          account_id: config.account,
          actor_id: actor.id,
          actor_name: actor.name || null,
          action: plan.action,
          kind: plan.kind,
          object_id: plan.id,
          request_hash: fingerprint(plan.params),
          expected_version: plan.expectedVersion,
          payload: { path: plan.path, params: plan.params },
          review: plan.review,
        });
        return res.status(200).json(record);
      }
      if (req.body.action === "execute") {
        if (!uuid(req.body.id) || req.body.confirmed !== true)
          throw problem("변경 내용을 확인한 뒤 반영해 주세요.");
        const operation = await store.get(req.body.id);
        if (
          !operation ||
          operation.account_id !== config.account ||
          operation.actor_id !== actor.id
        )
          throw problem("본인이 확인한 작업만 반영할 수 있습니다.", 403);
        if (operation.state === "succeeded")
          return res
            .status(200)
            .json({
              id: operation.id,
              state: operation.state,
              result: operation.result,
              repeated: true,
            });
        if (operation.state !== "prepared")
          throw problem(
            "이미 요청한 작업입니다. 변경 이력과 Meta 현재 상태를 확인해 주세요.",
            409,
            { operationId: operation.id },
          );
        if (Date.parse(operation.expires_at) <= Date.now())
          throw problem(
            "검토 유효시간 10분이 지났습니다. 다시 검토해 주세요.",
            409,
          );
        if (
          !operation.payload ||
          fingerprint(operation.payload.params) !== operation.request_hash
        )
          throw problem("저장한 변경 내용을 확인하지 못했습니다.", 409);
        if (!(await store.claim(operation.id)))
          throw problem(
            "이미 처리 중이거나 검토 시간이 지났습니다. 변경 이력을 확인해 주세요.",
            409,
          );
        let data;
        try {
          if (operation.object_id) {
            const current = await writeGraph.owned(
              operation.kind,
              operation.object_id,
            );
            if (current.version !== operation.expected_version)
              throw problem(
                "검토 이후 다른 곳에서 변경됐습니다. 새로고침 후 다시 검토해 주세요.",
                409,
              );
          }
          data = await writeGraph.request(
            operation.payload.path,
            operation.payload.params,
            "POST",
          );
          const valid =
            operation.action === "image"
              ? Object.values(data.images || {}).some((row) => row.hash)
              : operation.action === "copy"
                ? data[`copied_${operation.kind}_id`]
                : ["create", "video"].includes(operation.action)
                  ? data.id
                  : data.success === true;
          if (!valid)
            throw problem(
              "Meta의 처리 결과를 확인하지 못했습니다. 변경 이력과 현재 광고를 확인하고 재실행하지 마세요.",
              502,
              { uncertain: true },
            );
        } catch (error) {
          const state = error.uncertain ? "unknown" : "failed";
          const result = {
            error: error.message,
            providerCode: error.providerCode ?? null,
            providerSubcode: error.providerSubcode ?? null,
          };
          await store.finish(operation.id, state, result).catch(() => {});
          throw problem(error.message, error.status || 502, {
            operationId: operation.id,
            state,
            providerCode: error.providerCode,
          });
        }
        const result = summaryResult(data);
        try {
          await store.finish(operation.id, "succeeded", result);
        } catch {
          throw problem(
            "Meta는 요청을 처리했지만 이력 저장을 확인하지 못했습니다. 다시 실행하지 말고 현재 광고 상태를 조회해 주세요.",
            503,
            { operationId: operation.id, state: "unknown" },
          );
        }
        return res
          .status(200)
          .json({ id: operation.id, state: "succeeded", result });
      }
      throw problem("허용하지 않은 광고 작업입니다.");
    } catch (error) {
      const code = [
        400, 401, 403, 404, 409, 413, 415, 422, 429, 502, 503,
      ].includes(error.status)
        ? error.status
        : 503;
      return res
        .status(code)
        .json({
          error: error.status
            ? error.message
            : "광고 업무를 처리하지 못했습니다. 잠시 후 다시 조회해 주세요.",
          code,
          ...(error.operationId
            ? { operationId: error.operationId, state: error.state }
            : {}),
          ...(Number.isInteger(error.providerCode)
            ? { providerCode: error.providerCode }
            : {}),
        });
    }
  };
}
export default createMetaAdsHandler();
