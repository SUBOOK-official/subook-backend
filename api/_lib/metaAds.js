import { createHash } from "node:crypto";

// Meta 공식 v26 SDK/통화 문서로 검증. KRW offset=1: 입력한 원 금액을 그대로 보낸다.
export const META_ENTITY = Object.freeze({
  campaign: {
    edge: "campaigns",
    fields:
      "id,account_id,name,status,effective_status,objective,daily_budget,lifetime_budget,budget_remaining,bid_strategy,spend_cap,start_time,stop_time,updated_time,special_ad_categories",
  },
  adset: {
    edge: "adsets",
    fields:
      "id,account_id,campaign_id,name,status,effective_status,daily_budget,lifetime_budget,budget_remaining,start_time,end_time,optimization_goal,billing_event,bid_strategy,bid_amount,targeting,promoted_object,destination_type,updated_time",
  },
  ad: {
    edge: "ads",
    fields:
      "id,account_id,campaign_id,adset_id,name,status,effective_status,creative{id,name,thumbnail_url,object_story_spec,object_story_id,url_tags},issues_info,updated_time",
  },
  creative: {
    edge: "adcreatives",
    fields:
      "id,account_id,name,thumbnail_url,object_story_spec,object_story_id,body,title,link_url,url_tags",
  },
});
export const META_ASSETS = Object.freeze({
  pages: { edge: "promote_pages", fields: "id,name" },
  instagram: { edge: "instagram_accounts", fields: "id,username" },
  pixels: { edge: "adspixels", fields: "id,name" },
  images: {
    edge: "adimages",
    fields: "hash,name,url,width,height,created_time",
  },
  videos: {
    edge: "advideos",
    fields: "id,title,thumbnails{uri},status,length,created_time",
  },
  audiences: {
    edge: "customaudiences",
    fields: "id,name,subtype,delivery_status",
  },
  savedAudiences: { edge: "saved_audiences", fields: "id,name,targeting" },
});
const safeText = (v, max = 2000) =>
  String(v ?? "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "")
    .slice(0, max);
export function problem(message, status = 400, extra = {}) {
  return Object.assign(new Error(message), { status, ...extra });
}
export function metaId(value, label = "항목") {
  if (typeof value !== "string" || !/^\d{1,30}$/.test(value))
    throw problem(`${label}을 다시 선택해 주세요.`);
  return value;
}
export function entityKind(value) {
  if (!Object.hasOwn(META_ENTITY, value))
    throw problem("광고 종류를 확인해 주세요.");
  return value;
}
export function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  return value;
}
export function fingerprint(value) {
  return createHash("sha256")
    .update(JSON.stringify(canonical(value)))
    .digest("hex");
}
export function scrub(value) {
  if (Array.isArray(value)) return value.map(scrub);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value)
        .filter(
          ([key]) => !/access_token|secret|paging|__proto__|^body$/i.test(key),
        )
        .map(([key, item]) => [key, scrub(item)]),
    );
  return value;
}
function textField(
  value,
  label,
  max = 200,
  required = true,
  multiline = false,
) {
  if (
    typeof value !== "string" ||
    value.length > max ||
    (required && !value.trim()) ||
    (multiline
      ? /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/
      : /[\u0000-\u001f]/
    ).test(value)
  )
    throw problem(`${label}을 ${max}자 이내로 입력해 주세요.`);
  return value.trim();
}
function budget(value) {
  if (
    !/^\d+$/.test(String(value)) ||
    !Number.isSafeInteger(Number(value)) ||
    Number(value) < 1 ||
    Number(value) > 1_000_000_000
  )
    throw problem("예산은 1원부터 10억원까지 정수로 입력해 주세요.");
  return String(Number(value));
}
function dateTime(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{3})?)?(Z|[+-]\d{2}:\d{2})$/.test(
      value,
    ) ||
    !Number.isFinite(Date.parse(value))
  )
    throw problem("광고 시간을 다시 선택해 주세요.");
  return new Date(value).toISOString();
}
function selected(value, values, label) {
  if (!values.includes(value)) throw problem(`${label}을 다시 선택해 주세요.`);
  return value;
}
function onlyKeys(object, keys) {
  if (
    !object ||
    typeof object !== "object" ||
    Array.isArray(object) ||
    Object.keys(object).some((key) => !keys.includes(key))
  )
    throw problem(
      "지원하지 않는 입력 항목이 있습니다. 화면을 새로고침해 주세요.",
    );
}
export function landingUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw problem("수북 공개 페이지 주소를 입력해 주세요.");
  }
  if (
    url.origin !== "https://subook.kr" ||
    url.username ||
    url.password ||
    /^\/(admin|order|mypage|auth|api)(\/|$)/.test(url.pathname) ||
    url.searchParams.has("pg_review_mode")
  )
    throw problem(
      "광고 도착 주소는 수북의 공개 상품·스토어·이벤트 페이지를 사용해 주세요.",
    );
  if (url.href.length > 2000) throw problem("주소가 너무 깁니다.");
  for (const key of [...url.searchParams.keys()])
    if (key.startsWith("utm_")) url.searchParams.delete(key);
  return url.href;
}
function urlTags(values) {
  onlyKeys(values, ["source", "medium", "campaign", "id", "content"]);
  const params = new URLSearchParams();
  for (const key of ["source", "medium", "campaign", "id", "content"]) {
    const value = values[key];
    if (typeof value !== "string" || !/^[a-z0-9_.-]{1,100}$/.test(value))
      throw problem(
        "광고 출처·캠페인·소재 이름은 영문 소문자·숫자·밑줄로 입력해 주세요.",
      );
    if (key === "campaign" && (/^\d+$/.test(value) || value === "0803subook"))
      throw problem("캠페인에는 알아볼 수 있는 새로운 이름을 입력해 주세요.");
    if (key === "medium" && value === "organic")
      throw problem("유료 광고에는 cpc 등 광고 매체를 입력해 주세요.");
    params.set(`utm_${key}`, value);
  }
  return params.toString();
}
function targetChanges(value) {
  onlyKeys(value, [
    "age_min",
    "age_max",
    "genders",
    "countries",
    "publisher_platforms",
    "custom_audiences",
    "excluded_custom_audiences",
  ]);
  const target = {};
  if ("age_min" in value || "age_max" in value) {
    const min = Number(value.age_min),
      max = Number(value.age_max);
    if (
      !Number.isInteger(min) ||
      !Number.isInteger(max) ||
      min < 18 ||
      max > 65 ||
      min > max
    )
      throw problem("연령은 18~65세 범위에서 시작·종료를 입력해 주세요.");
    target.age_min = min;
    target.age_max = max;
  }
  if ("genders" in value) {
    if (
      !Array.isArray(value.genders) ||
      value.genders.length > 2 ||
      value.genders.some((v) => ![1, 2].includes(v))
    )
      throw problem("성별 선택을 확인해 주세요.");
    target.genders = [...new Set(value.genders)];
  }
  if ("countries" in value) {
    if (
      !Array.isArray(value.countries) ||
      !value.countries.length ||
      value.countries.length > 20 ||
      value.countries.some((v) => !/^[A-Z]{2}$/.test(v))
    )
      throw problem("대상 국가를 확인해 주세요.");
    target.geo_locations = { countries: [...new Set(value.countries)] };
  }
  if ("publisher_platforms" in value) {
    if (
      !Array.isArray(value.publisher_platforms) ||
      !value.publisher_platforms.length ||
      value.publisher_platforms.some(
        (v) =>
          ![
            "facebook",
            "instagram",
            "audience_network",
            "messenger",
            "threads",
          ].includes(v),
      )
    )
      throw problem("게재 위치를 확인해 주세요.");
    target.publisher_platforms = [...new Set(value.publisher_platforms)];
  }
  for (const key of ["custom_audiences", "excluded_custom_audiences"])
    if (key in value) {
      if (!Array.isArray(value[key]) || value[key].length > 20)
        throw problem("대상 그룹은 20개까지 선택할 수 있습니다.");
      target[key] = value[key].map((id) => ({ id: metaId(id, "대상 그룹") }));
    }
  return target;
}
export function validateMutation(input) {
  onlyKeys(input, ["action", "kind", "id", "values", "version"]);
  const action = selected(
    input.action,
    ["create", "update", "status", "copy", "image", "video"],
    "작업",
  );
  const kind = entityKind(input.kind);
  const values = input.values;
  const id = ["update", "status", "copy"].includes(action)
    ? metaId(input.id)
    : null;
  const result = {
    action,
    kind,
    id,
    version: input.version || null,
    params: {},
  };
  if (action === "status") {
    if (kind === "creative")
      throw problem("소재는 광고에서 사용 여부를 관리합니다.");
    onlyKeys(values, ["status"]);
    result.params.status = selected(
      values.status,
      ["ACTIVE", "PAUSED", "ARCHIVED"],
      "상태",
    );
    return result;
  }
  if (action === "copy") {
    if (kind === "creative")
      throw problem("소재를 선택해 새 광고를 만들어 주세요.");
    onlyKeys(values, ["suffix", "deepCopy"]);
    result.params = {
      status_option: "PAUSED",
      rename_options: {
        rename_suffix: textField(values.suffix, "복사본 이름 접미사", 40),
      },
    };
    if (kind !== "ad") result.params.deep_copy = values.deepCopy === true;
    return result;
  }
  if (action === "image") {
    onlyKeys(values, ["bytes", "name"]);
    if (
      kind !== "creative" ||
      typeof values.bytes !== "string" ||
      values.bytes.length > 4_000_000 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(values.bytes)
    )
      throw problem("이미지는 3MB 이하 PNG·JPEG를 선택해 주세요.");
    const bytes = Buffer.from(values.bytes, "base64");
    if (
      !(
        bytes.subarray(0, 3).equals(Buffer.from([255, 216, 255])) ||
        bytes
          .subarray(0, 8)
          .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
      )
    )
      throw problem("PNG·JPEG 이미지 파일만 업로드할 수 있습니다.");
    result.params = { bytes: values.bytes };
    result.displayName = textField(values.name, "파일 이름");
    return result;
  }
  if (action === "video") {
    onlyKeys(values, ["url", "name"]);
    if (kind !== "creative") throw problem("동영상 소재를 선택해 주세요.");
    let url;
    try {
      url = new URL(values.url);
    } catch {
      throw problem("동영상 파일 주소를 입력해 주세요.");
    }
    // Meta가 받는 공개 동영상 주소만 지원한다. 서버에서 임의 URL을 내려받지 않는다.
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      !/\.mp4$/i.test(url.pathname) ||
      url.search ||
      url.hash ||
      /(^localhost$|^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2\d|3[01])\.|:)/.test(
        url.hostname,
      )
    )
      throw problem("인증정보가 없는 공개 HTTPS MP4 주소를 사용해 주세요.");
    result.params = {
      file_url: url.href,
      name: textField(values.name, "영상 이름"),
    };
    return result;
  }
  const fields =
    kind === "campaign"
      ? ["name", "objective", "budgetType", "budget", "start_time", "stop_time"]
      : kind === "adset"
        ? [
            "name",
            "campaign_id",
            "budgetType",
            "budget",
            "start_time",
            "end_time",
            "targeting",
            "pixel_id",
            "optimization_goal",
          ]
        : kind === "ad"
          ? ["name", "adset_id", "creative_id"]
          : [
              "name",
              "page_id",
              "instagram_id",
              "format",
              "image_hash",
              "video_id",
              "thumbnail_url",
              "message",
              "title",
              "description",
              "link",
              "cta",
              "post_id",
              "tracking",
            ];
  onlyKeys(values, fields);
  const create = action === "create";
  if (create || "name" in values)
    result.params.name = textField(values.name, "이름");
  if (create && kind !== "creative") result.params.status = "PAUSED";
  if ("budget" in values || "budgetType" in values) {
    if (!["campaign", "adset"].includes(kind))
      throw problem("예산은 캠페인 또는 광고세트에서 설정합니다.");
    selected(values.budgetType, ["daily", "lifetime"], "예산 방식");
    result.params[`${values.budgetType}_budget`] = budget(values.budget);
  }
  for (const key of ["start_time", "end_time", "stop_time"])
    if (key in values) result.params[key] = dateTime(values[key]);
  const end = result.params.end_time || result.params.stop_time;
  if (end && Date.parse(end) <= Date.now())
    throw problem("종료 시간은 현재보다 뒤여야 합니다.");
  if (
    end &&
    result.params.start_time &&
    Date.parse(end) <= Date.parse(result.params.start_time)
  )
    throw problem("종료 시간은 시작 시간보다 뒤여야 합니다.");
  if (kind === "campaign") {
    if (create) {
      result.params.objective = selected(
        values.objective,
        ["OUTCOME_SALES", "OUTCOME_TRAFFIC"],
        "광고 목표",
      );
      result.params.special_ad_categories = [];
      result.params.buying_type = "AUCTION";
      result.params.is_adset_budget_sharing_enabled = false;
      if (result.params.daily_budget || result.params.lifetime_budget)
        result.params.bid_strategy = "LOWEST_COST_WITHOUT_CAP";
    } else if ("objective" in values)
      throw problem(
        "기존 캠페인의 목표는 변경할 수 없습니다. 새 캠페인을 만들어 주세요.",
      );
  }
  if (kind === "adset") {
    if (create) {
      result.params.campaign_id = metaId(values.campaign_id, "캠페인");
      result.params.optimization_goal = selected(
        values.optimization_goal,
        ["OFFSITE_CONVERSIONS", "LANDING_PAGE_VIEWS", "LINK_CLICKS"],
        "성과 목표",
      );
      result.params.billing_event = "IMPRESSIONS";
      result.params.destination_type = "WEBSITE";
      result.params.bid_strategy = "LOWEST_COST_WITHOUT_CAP";
      if (!values.targeting?.countries?.length)
        throw problem("광고 대상 국가를 설정해 주세요.");
    } else if (
      "campaign_id" in values ||
      "optimization_goal" in values ||
      "pixel_id" in values
    )
      throw problem("캠페인·성과 목표 변경은 새 광고세트를 만들어 주세요.");
    if ("targeting" in values)
      result.params.targeting = targetChanges(values.targeting);
    if (create && values.optimization_goal === "OFFSITE_CONVERSIONS")
      result.params.promoted_object = {
        pixel_id: metaId(values.pixel_id, "구매 픽셀"),
        custom_event_type: "PURCHASE",
      };
  }
  if (kind === "ad") {
    if (create) result.params.adset_id = metaId(values.adset_id, "광고세트");
    else if ("adset_id" in values)
      throw problem("광고세트 이동은 복사 또는 새 광고로 진행해 주세요.");
    if (create || "creative_id" in values)
      result.params.creative = {
        creative_id: metaId(values.creative_id, "소재"),
      };
  }
  if (kind === "creative") {
    if (!create && Object.keys(values).some((key) => key !== "name"))
      throw problem(
        "문구·이미지 변경은 새 소재를 만든 뒤 광고에서 교체해 주세요.",
      );
    if (create) {
      const format = selected(
        values.format,
        ["image", "video", "post"],
        "소재 형식",
      );
      if (format === "post") {
        if (!/^\d{1,30}_\d{1,30}$/.test(values.post_id ?? ""))
          throw problem(
            "게시물 ID는 페이지ID_게시물ID 형식으로 입력해 주세요.",
          );
        result.params.object_story_id = values.post_id;
      } else {
        const page = metaId(values.page_id, "Facebook 페이지");
        const link = landingUrl(values.link);
        const cta = selected(
          values.cta,
          ["SHOP_NOW", "LEARN_MORE", "SIGN_UP", "CONTACT_US"],
          "버튼",
        );
        const message = textField(values.message, "본문", 2000, true, true);
        const title = textField(values.title, "제목", 150);
        const story = { page_id: page };
        if (values.instagram_id)
          story.instagram_user_id = metaId(
            values.instagram_id,
            "Instagram 계정",
          );
        if (format === "image") {
          if (!/^[a-f0-9]{16,64}$/i.test(values.image_hash ?? ""))
            throw problem("계정에 업로드한 이미지를 선택해 주세요.");
          story.link_data = {
            image_hash: values.image_hash,
            link,
            message,
            name: title,
            description: textField(
              values.description ?? "",
              "설명",
              300,
              false,
            ),
            call_to_action: { type: cta, value: { link } },
          };
        } else {
          let thumbnail;
          try {
            thumbnail = new URL(values.thumbnail_url);
          } catch {
            throw problem("영상 썸네일을 선택해 주세요.");
          }
          if (
            thumbnail.protocol !== "https:" ||
            thumbnail.username ||
            thumbnail.password
          )
            throw problem("썸네일 주소를 확인해 주세요.");
          story.video_data = {
            video_id: metaId(values.video_id, "동영상"),
            image_url: thumbnail.href,
            message,
            title,
            call_to_action: { type: cta, value: { link } },
          };
        }
        result.params.object_story_spec = story;
      }
      result.params.url_tags = urlTags(values.tracking);
    }
  }
  if (!Object.keys(result.params).length)
    throw problem("변경할 내용을 입력해 주세요.");
  return result;
}

export function metaConfig(env = process.env, write = false) {
  const account = env.META_AD_ACCOUNT_ID?.replace(/^act_/, "");
  const version = env.META_GRAPH_API_VERSION || "v26.0";
  const token = write
    ? env.META_ADS_MANAGEMENT_TOKEN
    : env.META_ADS_MANAGEMENT_TOKEN || env.META_ADS_ACCESS_TOKEN;
  if (!/^\d{1,30}$/.test(account ?? "") || !/^v\d+\.0$/.test(version))
    throw problem("Meta 광고 계정 연결을 확인해 주세요.", 503);
  if (!token)
    throw problem(
      write
        ? "광고 관리 권한 연결이 필요합니다. 조회와 초안 저장은 계속 사용할 수 있습니다."
        : "Meta 광고 조회 연결이 필요합니다.",
      503,
    );
  return { account, version, token };
}
export function createMetaGraph(config, fetcher = fetch) {
  const request = async (path, params = {}, method = "GET") => {
    if (!/^(me|act_\d+|\d+)(\/[a-z_]+)?$/.test(path))
      throw problem("허용하지 않은 Meta 경로입니다.");
    const fields = new URLSearchParams();
    for (const [key, value] of Object.entries(params))
      if (value !== undefined && value !== null)
        fields.set(
          key,
          typeof value === "object" ? JSON.stringify(value) : String(value),
        );
    const attempts = method === "GET" ? 2 : 1;
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        const response = await fetcher(
          `https://graph.facebook.com/${config.version}/${path}${method === "GET" ? `?${fields}` : ""}`,
          {
            method,
            headers: {
              Authorization: `Bearer ${config.token}`,
              ...(method !== "GET"
                ? { "Content-Type": "application/x-www-form-urlencoded" }
                : {}),
            },
            ...(method !== "GET" ? { body: fields.toString() } : {}),
            signal: AbortSignal.timeout(method === "GET" ? 10000 : 20000),
          },
        );
        const data = await response.json().catch(() => null);
        if (response.ok && data && !data.error) return data;
        const transient =
          response.status === 429 ||
          response.status >= 500 ||
          data?.error?.is_transient === true;
        if (method === "GET" && transient && attempt + 1 < attempts) {
          await new Promise((resolve) => setTimeout(resolve, 300));
          continue;
        }
        const remote = data?.error;
        const message = remote?.error_user_msg
          ? safeText(remote.error_user_msg, 600)
          : remote?.code === 190
            ? "Meta 연결이 만료됐습니다. 계정 연결을 확인해 주세요."
            : [10, 200].includes(remote?.code)
              ? "Meta 자산 권한 또는 개발자 계정 확인이 필요합니다."
              : "Meta가 요청을 처리하지 못했습니다. 입력과 계정 상태를 확인해 주세요.";
        throw problem(message.replaceAll(config.token, "[보안정보]"), 502, {
          providerCode: remote?.code ?? null,
          providerSubcode: remote?.error_subcode ?? null,
          uncertain: method !== "GET" && (!data || response.status >= 500),
        });
      } catch (error) {
        if (error.status) throw error;
        if (method === "GET" && attempt + 1 < attempts) continue;
        throw problem(
          method === "GET"
            ? "Meta 응답이 지연되고 있습니다. 다시 조회해 주세요."
            : "Meta 응답을 확인하지 못했습니다. 중복 반영을 피하기 위해 자동 재시도하지 않았습니다. 변경 이력을 확인해 주세요.",
          502,
          { uncertain: method !== "GET" },
        );
      }
    }
  };
  const list = async (path, params = {}) => {
    const data = await request(path, { ...params, limit: 50 });
    if (!Array.isArray(data.data))
      throw problem("Meta 목록 응답을 확인하지 못했습니다.", 502);
    return {
      rows: scrub(data.data),
      after:
        data.paging?.next && data.paging?.cursors?.after
          ? data.paging.cursors.after
          : null,
    };
  };
  const owned = async (kind, id) => {
    const data = await request(metaId(id), {
      fields: META_ENTITY[entityKind(kind)].fields,
    });
    if (String(data.account_id) !== config.account)
      throw problem("연결된 광고 계정의 항목만 관리할 수 있습니다.", 403);
    return { ...scrub(data), version: fingerprint(scrub(data)) };
  };
  return { request, list, owned, config };
}

export async function connection(graph) {
  const [account, permissions] = await Promise.all([
    graph.request(`act_${graph.config.account}`, {
      fields:
        "id,account_id,name,currency,timezone_name,account_status,disable_reason,amount_spent,balance,spend_cap,user_tasks",
    }),
    graph.request("me/permissions").catch(() => ({ data: [] })),
  ]);
  if (account.currency !== "KRW" || account.timezone_name !== "Asia/Seoul")
    throw problem(
      "현재 광고 운영 화면은 원화·한국시간 계정만 지원합니다.",
      409,
    );
  const scopes = (permissions.data ?? [])
    .filter((row) => row.status === "granted")
    .map((row) => row.permission);
  const canManage =
    scopes.includes("ads_management") &&
    (account.user_tasks ?? []).some((task) =>
      ["ADVERTISE", "MANAGE"].includes(task),
    );
  return {
    account: scrub(account),
    canManage,
    scopes: scopes.filter((v) =>
      [
        "ads_read",
        "ads_management",
        "pages_read_engagement",
        "pages_manage_ads",
        "business_management",
      ].includes(v),
    ),
  };
}

export async function prepareMutation(graph, input) {
  const operation = validateMutation(input);
  let current = null;
  if (operation.id) {
    current = await graph.owned(operation.kind, operation.id);
    if (input.version !== current.version)
      throw problem(
        "다른 곳에서 내용이 변경됐습니다. 새로고침 후 다시 확인해 주세요.",
        409,
      );
    if (
      ["ARCHIVED", "DELETED"].includes(current.status) &&
      operation.action !== "copy"
    )
      throw problem("보관·삭제된 항목은 복사해서 새로 사용해 주세요.", 409);
  }
  const params = operation.params;
  // 클라이언트가 보낸 자산 ID도 연결된 계정의 목록에서 다시 확인한다.
  const assertAssets = async (kind, ids, field = "id") => {
    const missing = new Set(ids.filter(Boolean));
    if (!missing.size) return;
    let after;
    for (let page = 0; page < 20 && missing.size; page++) {
      const data = await graph.list(
        `act_${graph.config.account}/${META_ASSETS[kind].edge}`,
        { fields: field, after },
      );
      data.rows.forEach((row) => missing.delete(String(row[field])));
      if (!data.after || data.after === after) break;
      after = data.after;
    }
    if (missing.size)
      throw problem(
        "연결된 광고 계정에서 사용할 수 있는 자산을 선택해 주세요. 목록을 새로고침해 주세요.",
        403,
      );
  };
  const assetChecks = [];
  if (params.promoted_object?.pixel_id)
    assetChecks.push(assertAssets("pixels", [params.promoted_object.pixel_id]));
  if (params.targeting)
    assetChecks.push(
      assertAssets(
        "audiences",
        [
          ...(params.targeting.custom_audiences || []),
          ...(params.targeting.excluded_custom_audiences || []),
        ].map((row) => row.id),
      ),
    );
  if (params.object_story_id)
    assetChecks.push(
      assertAssets("pages", [params.object_story_id.split("_")[0]]),
    );
  const story = params.object_story_spec;
  if (story) {
    assetChecks.push(assertAssets("pages", [story.page_id]));
    if (story.instagram_user_id)
      assetChecks.push(assertAssets("instagram", [story.instagram_user_id]));
    if (story.link_data)
      assetChecks.push(
        assertAssets("images", [story.link_data.image_hash], "hash"),
      );
    if (story.video_data)
      assetChecks.push(assertAssets("videos", [story.video_data.video_id]));
  }
  await Promise.all(assetChecks);
  if (operation.kind === "adset" && operation.action === "create") {
    const campaign = await graph.owned("campaign", params.campaign_id);
    if (campaign.special_ad_categories?.length)
      throw problem("특별 광고 카테고리는 Meta의 전용 설정을 사용해 주세요.");
    if (
      (campaign.objective === "OUTCOME_SALES" &&
        params.optimization_goal !== "OFFSITE_CONVERSIONS") ||
      (campaign.objective === "OUTCOME_TRAFFIC" &&
        !["LANDING_PAGE_VIEWS", "LINK_CLICKS"].includes(
          params.optimization_goal,
        ))
    )
      throw problem("캠페인 목표에 맞는 광고세트 성과 목표를 선택해 주세요.");
    if (!["OUTCOME_SALES", "OUTCOME_TRAFFIC"].includes(campaign.objective))
      throw problem(
        "새 광고세트는 웹사이트 판매·트래픽 캠페인에 만들 수 있습니다.",
      );
    const campaignBudget =
      Number(campaign.daily_budget) > 0 || Number(campaign.lifetime_budget) > 0;
    if (campaignBudget && (params.daily_budget || params.lifetime_budget))
      throw problem(
        "이 캠페인은 캠페인 예산을 사용합니다. 광고세트 예산을 비워 주세요.",
      );
    if (!campaignBudget && !params.daily_budget && !params.lifetime_budget)
      throw problem("광고세트 예산을 입력해 주세요.");
    if (campaignBudget) delete params.bid_strategy;
  }
  if (
    operation.kind === "adset" &&
    current &&
    (params.daily_budget || params.lifetime_budget)
  ) {
    const campaign = await graph.owned("campaign", current.campaign_id);
    if (
      Number(campaign.daily_budget) > 0 ||
      Number(campaign.lifetime_budget) > 0
    )
      throw problem(
        "캠페인 예산을 사용하는 광고입니다. 캠페인에서 예산을 수정해 주세요.",
      );
  }
  if (
    current &&
    ((params.daily_budget && Number(current.lifetime_budget) > 0) ||
      (params.lifetime_budget && Number(current.daily_budget) > 0))
  )
    throw problem("일일·총예산 방식은 유지하고 금액만 변경해 주세요.");
  if (operation.kind === "adset" && params.targeting && current) {
    const campaign = await graph.owned("campaign", current.campaign_id);
    if (campaign.special_ad_categories?.length)
      throw problem("특별 광고 카테고리의 대상 설정은 Meta에서 확인해 주세요.");
    if (
      "geo_locations" in params.targeting &&
      Object.keys(current.targeting?.geo_locations ?? {}).some(
        (key) => key !== "countries",
      )
    )
      throw problem(
        "도시·반경 등 세부 지역이 설정된 광고는 국가 일괄 변경을 지원하지 않습니다.",
      );
    const changesPlatforms = "publisher_platforms" in params.targeting;
    params.targeting = { ...current.targeting, ...params.targeting };
    if (changesPlatforms) {
      for (const [platform, field] of [
        ["facebook", "facebook_positions"],
        ["instagram", "instagram_positions"],
        ["messenger", "messenger_positions"],
        ["audience_network", "audience_network_positions"],
        ["threads", "threads_positions"],
      ]) {
        if (!params.targeting.publisher_platforms?.includes(platform))
          delete params.targeting[field];
      }
    }
  }
  if (
    params.lifetime_budget &&
    !(
      params.end_time ||
      params.stop_time ||
      current?.end_time ||
      current?.stop_time
    )
  )
    throw problem("총예산을 사용할 때는 종료 시간을 입력해 주세요.");
  const start = params.start_time || current?.start_time;
  const end =
    params.end_time ||
    params.stop_time ||
    current?.end_time ||
    current?.stop_time;
  if (start && end && Date.parse(end) <= Date.parse(start))
    throw problem("종료 시간은 시작 시간 이후여야 합니다.");
  if (operation.kind === "ad" && params.adset_id)
    await graph.owned("adset", params.adset_id);
  if (operation.kind === "ad" && params.creative)
    await graph.owned("creative", params.creative.creative_id);
  const path =
    operation.action === "copy"
      ? `${operation.id}/copies`
      : operation.action === "image"
        ? `act_${graph.config.account}/adimages`
        : operation.action === "video"
          ? `act_${graph.config.account}/advideos`
          : operation.action === "create"
            ? `act_${graph.config.account}/${META_ENTITY[operation.kind].edge}`
            : operation.id;
  const before = current
    ? Object.fromEntries(
        Object.keys(params)
          .filter((key) => key in current)
          .map((key) => [key, current[key]]),
      )
    : null;
  return {
    ...operation,
    path,
    before,
    expectedVersion: current?.version ?? null,
    review: {
      kind: operation.kind,
      action: operation.action,
      name:
        params.name || operation.displayName || current?.name || "광고 작업",
      before,
      after:
        operation.action === "image"
          ? {
              name: operation.displayName,
              bytes: Math.ceil((params.bytes.length * 3) / 4),
            }
          : scrub(params),
      startsSpend: params.status === "ACTIVE",
      changesLive:
        current?.effective_status === "ACTIVE" && operation.action === "update",
    },
  };
}
