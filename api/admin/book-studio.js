import { createClient } from "@supabase/supabase-js";
import { generateStudioImage } from "../_lib/studioImage.js";

// 표지: GPT Image 2.5 Sunburst medium / 상품 AI 설명(mode: "summary"): Gemini.
// summary URL은 DB 트리거·pg_cron에서 호출하므로 분기와 인증 규칙을 유지한다.
const MAX_IMAGE_BASE64_LENGTH = 3_000_000;
const allowedInputMimeTypes = new Set(["image/jpeg", "image/png", "image/webp"]);

function makeErrorResponse({ error, code, detail }) {
  const payload = {
    error: String(error || "Request failed."),
    code: String(code || "UNKNOWN"),
  };

  if (detail) {
    payload.detail = String(detail);
  }

  return payload;
}

function getErrorDetail(error) {
  const candidates = [
    error?.message,
    error?.error?.message,
    error?.cause?.message,
    error?.response?.data?.error?.message,
    error?.response?.data?.message,
  ];

  for (const candidate of candidates) {
    const text = String(candidate || "").trim();
    if (text) {
      return text.length > 500 ? `${text.slice(0, 500)}...` : text;
    }
  }

  return "";
}

function makeTimeoutError(timeoutMs) {
  const error = new Error(`Model response exceeded ${timeoutMs}ms.`);
  error.status = 504;
  error.code = "GEMINI_TIMEOUT";
  return error;
}


function getSupabaseConfig() {
  const url =
    process.env.SUPABASE_ADMIN_URL || process.env.VITE_SUPABASE_ADMIN_URL;
  const anonKey =
    process.env.SUPABASE_ADMIN_ANON_KEY || process.env.VITE_SUPABASE_ADMIN_ANON_KEY;

  return { url, anonKey };
}

function getGeminiApiKey() {
  return process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || "";
}

function parseBearerToken(authHeader) {
  const raw = String(authHeader || "");
  const match = raw.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || "";
}

function isBase64(value) {
  return /^[A-Za-z0-9+/=]+$/.test(value);
}

async function assertAdminUser(accessToken) {
  const { url, anonKey } = getSupabaseConfig();
  if (!url || !anonKey) {
    const error = new Error("SUPABASE_CONFIG_MISSING");
    error.statusCode = 500;
    throw error;
  }

  const supabase = createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userResult, error: userError } = await supabase.auth.getUser(accessToken);
  if (userError || !userResult?.user) {
    const error = new Error("UNAUTHORIZED");
    error.statusCode = 401;
    throw error;
  }

  const { data: isAdmin, error: adminError } = await supabase.rpc("is_admin_user");
  if (adminError || !isAdmin) {
    const error = new Error("FORBIDDEN");
    error.statusCode = 403;
    throw error;
  }
}

// ── 상품 AI 요약 단건 생성 (mode: "summary") ─────────────────────────
// 생성 규칙은 backend/scripts/generate-ai-summaries.mjs의 검증된 로직 이식:
// gemini-3.8-flash + 검색 그라운딩(camelCase googleSearch 필수 — snake_case는
// 조용히 무시됨), thinking 파트 제외, maxOutputTokens 4096(2048은 잘림),
// finishReason!=="STOP" 실패 처리, 출처 0이면 1회 재시도, option 미포함(분권 앵커링 방지).

const SUMMARY_MODEL_ID = process.env.GEMINI_SUMMARY_MODEL_ID || "gemini-3.8-flash";
const SUMMARY_ATTEMPT_TIMEOUT_MS = 45_000;

function getSupabaseRestConfig() {
  const url =
    process.env.SUPABASE_URL ||
    process.env.SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_URL;
  const serviceKey =
    process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;
  return { url, serviceKey };
}

function buildSummaryPrompt(product) {
  // ⚠ product.option(분권명)은 프롬프트에 넣지 않는다 (2026-07-13 피드백).
  const facts = [
    `- 제목: ${product.title}`,
    `- 과목: ${product.subject ?? "미상"} / 유형: ${product.book_type ?? "미상"} / 출판연도: ${product.published_year ?? "미상"}`,
    `- 브랜드/출판사: ${product.brand ?? "미상"} / 강사: ${product.instructor_name ?? "미상"}`,
  ].join("\n");

  return `당신은 수능 교재 중고거래 플랫폼 '수북'의 교재 소개 작성자입니다.
먼저 반드시 구글 검색을 실행해 제목·브랜드/출판사·출판연도·강사가 일치하는 교재인지 교차 확인한 뒤, 이 교재를 처음 보는 수험생에게 도움이 되는 소개를 작성하세요. 검색 없이 기억만으로 쓰거나 제목이 비슷한 다른 교재의 정보를 섞지 마세요.

[교재 정보 — 우리 데이터베이스의 확정 사실]
${facts}

[작성 규칙]
1. 이 상품은 같은 교재의 여러 분권·옵션(예: 수학1+수학2 / 미적분, 회차별)으로 판매될 수 있습니다. 특정 분권이 아니라 교재(시리즈) 전체를 일반화해서 소개하고, 분권명을 제목처럼 확정해 쓰지 마세요.
2. 검색으로 확인된 내용만 쓰고, "~라는 평가가 많아요", "~로 알려져 있어요"처럼 근거가 검색임이 드러나게 쓰세요. 검색 결과가 우리 DB의 제목·브랜드·연도·강사와 정확히 일치하지 않으면 그 내용을 사실처럼 쓰지 마세요.
3. 실제 판매 구성으로 오해할 수 있는 분권 범위, 회차, 부록·답지 포함 여부, 목차, 문항 수, 개정판 차이는 검색 결과가 있어도 절대 언급하지 마세요. 실제 구성은 판매 옵션과 상세 사진에서만 안내합니다.
4. 정확히 일치하는 검색 근거가 부족한 교재라면 구체적인 난이도·구성·평가를 만들지 말고, 해당 과목·유형의 일반적인 활용 방법만 안내하세요.
5. 한국어 존댓말로 3~4문장, 문단 하나로만. 이모지·과장 광고 문구·목록·헤더 금지.
6. 가독성을 위해 핵심 구절(난이도 특징, 추천 대상, 활용 포인트) 2~4곳만 **볼드**로 강조하세요. 볼드 외의 마크다운은 금지.
7. 중고 매물의 상태나 가격은 언급하지 마세요 (페이지에 별도로 표시됩니다).
8. 소개 본문만 출력하세요 (제목·인사말·부연 설명 금지).`;
}

async function requestGeminiSummary({ apiKey, product }) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), SUMMARY_ATTEMPT_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${SUMMARY_MODEL_ID}:generateContent`,
      {
        method: "POST",
        headers: { "x-goog-api-key": apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: buildSummaryPrompt(product) }] }],
          // ⚠ camelCase 필수 — snake_case(google_search)는 조용히 무시됨 (실측)
          tools: [{ googleSearch: {} }],
          // Gemini 3.8 이전 지침에 따라 temperature 제거, 짧은 소개는 low 추론으로 생성.
          // https://ai.google.dev/gemini-api/docs/latest-model
          generationConfig: {
            thinkingConfig: { thinkingLevel: "LOW" },
            maxOutputTokens: 4096,
          },
        }),
        signal: controller.signal,
      },
    );
  } catch (error) {
    if (error?.name === "AbortError") {
      throw makeTimeoutError(SUMMARY_ATTEMPT_TIMEOUT_MS);
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`Gemini ${response.status}: ${JSON.stringify(data).slice(0, 300)}`);
  }

  const candidate = data?.candidates?.[0];
  // 토큰 예산 소진(MAX_TOKENS) 등으로 잘린 응답은 불완전 — 실패 처리해 재시도 유도
  if (candidate?.finishReason && candidate.finishReason !== "STOP") {
    throw new Error(`불완전 응답 (finishReason=${candidate.finishReason})`);
  }
  // thinking 모델은 사고 과정 파트(thought: true)를 함께 반환 — 최종 답변 파트만 사용
  const text = (candidate?.content?.parts ?? [])
    .filter((part) => !part.thought)
    .map((part) => part.text ?? "")
    .join("")
    .trim();

  const sources = [];
  for (const chunk of candidate?.groundingMetadata?.groundingChunks ?? []) {
    if (chunk?.web?.uri && !sources.some((s) => s.uri === chunk.web.uri)) {
      sources.push({ uri: chunk.web.uri, title: chunk.web.title ?? "" });
    }
    if (sources.length >= 5) break;
  }

  return { text, sources };
}

async function generateSummaryWithRetries({ apiKey, product }) {
  let result;
  try {
    result = await requestGeminiSummary({ apiKey, product });
  } catch {
    // 일시 오류/불완전 응답은 1회 재시도
    await new Promise((r) => setTimeout(r, 2000));
    result = await requestGeminiSummary({ apiKey, product });
  }
  // 검색이 실행되지 않은(출처 0) 응답은 1회 더 시도 — 그래도 0이면
  // 유형 일반론 fallback 규칙이 있으므로 그 결과를 그대로 저장한다.
  if (result.sources.length === 0) {
    await new Promise((r) => setTimeout(r, 2000));
    const retry = await requestGeminiSummary({ apiKey, product }).catch(() => null);
    if (retry && retry.sources.length > 0) {
      result = retry;
    }
  }
  return result;
}

async function handleSummaryMode(req, res, body) {
  const { url: supabaseUrl, serviceKey } = getSupabaseRestConfig();
  const geminiApiKey = getGeminiApiKey();
  // fail-close: 서버 키 미설정이면 인증 판단 자체가 불가 → 차단
  if (!supabaseUrl || !serviceKey || !geminiApiKey) {
    console.error("[book-studio:summary] missing server configuration");
    return res.status(500).json(
      makeErrorResponse({ error: "Server misconfigured.", code: "SUMMARY_CONFIG_MISSING" }),
    );
  }

  // 인증: pg_net(DB 트리거/스위퍼)은 body.token, 수동 호출은 Bearer 헤더
  const bearer = parseBearerToken(req.headers.authorization);
  const cronSecret = process.env.CRON_SECRET;
  const authorized =
    (body.token && body.token === serviceKey) ||
    (bearer && bearer === serviceKey) ||
    (bearer && cronSecret && bearer === cronSecret);
  if (!authorized) {
    return res.status(401).json(
      makeErrorResponse({ error: "Unauthorized.", code: "SUMMARY_UNAUTHORIZED" }),
    );
  }

  const productId = Number(body.productId);
  if (!Number.isInteger(productId) || productId <= 0) {
    return res.status(400).json(
      makeErrorResponse({ error: "productId must be a positive integer.", code: "SUMMARY_BAD_PRODUCT_ID" }),
    );
  }

  const restHeaders = {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };

  try {
    const productRes = await fetch(
      `${supabaseUrl}/rest/v1/products?id=eq.${productId}&select=id,title,subject,brand,book_type,published_year,instructor_name,ai_summary`,
      { headers: restHeaders },
    );
    const rows = await productRes.json().catch(() => null);
    if (!productRes.ok || !Array.isArray(rows)) {
      console.error("[book-studio:summary] product fetch failed", productRes.status);
      return res.status(502).json(
        makeErrorResponse({ error: "Failed to load product.", code: "SUMMARY_PRODUCT_FETCH_FAILED" }),
      );
    }
    const product = rows[0];
    if (!product) {
      return res.status(404).json(
        makeErrorResponse({ error: "Product not found.", code: "SUMMARY_PRODUCT_NOT_FOUND" }),
      );
    }
    // 멱등: 이미 요약이 있으면 재생성하지 않음 (트리거·스위퍼 중복 호출 대비)
    if (product.ai_summary) {
      return res.status(200).json({ ok: true, id: productId, skipped: "exists" });
    }

    const { text, sources } = await generateSummaryWithRetries({
      apiKey: geminiApiKey,
      product,
    });
    if (!text || text.length < 40) {
      throw new Error(`생성 결과가 너무 짧음 (${text?.length ?? 0}자)`);
    }

    const patchRes = await fetch(`${supabaseUrl}/rest/v1/products?id=eq.${productId}`, {
      method: "PATCH",
      headers: { ...restHeaders, Prefer: "return=minimal" },
      body: JSON.stringify({
        ai_summary: text,
        ai_summary_sources: sources,
        ai_summary_generated_at: new Date().toISOString(),
      }),
    });
    if (!patchRes.ok) {
      throw new Error(`저장 실패 HTTP ${patchRes.status}`);
    }

    console.log(
      `[book-studio:summary] #${productId} OK (${text.length}자, 출처 ${sources.length})`,
    );
    return res.status(200).json({
      ok: true,
      id: productId,
      chars: text.length,
      sources: sources.length,
    });
  } catch (error) {
    console.error(`[book-studio:summary] #${productId} failed:`, error?.message || error);
    return res.status(502).json(
      makeErrorResponse({
        error: "Failed to generate summary.",
        code: "SUMMARY_GENERATION_FAILED",
        detail: getErrorDetail(error),
      }),
    );
  }
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json(
      makeErrorResponse({
        error: "Method not allowed.",
        code: "METHOD_NOT_ALLOWED",
      }),
    );
  }

  try {
    // body를 인증보다 먼저 파싱 — summary 모드는 body.token으로 인증하기 때문.
    // (표지 모드 기준 변화: 잘못된 JSON이 401보다 먼저 400을 받게 됨 — 무해)
    let body = {};
    try {
      body =
        typeof req.body === "string" ? JSON.parse(req.body || "{}") : req.body || {};
    } catch (_parseError) {
      return res.status(400).json(
        makeErrorResponse({
          error: "Invalid JSON body.",
          code: "INVALID_JSON_BODY",
        }),
      );
    }

    // AI 요약 단건 생성 분기 (인증 포함 자체 처리)
    if (body?.mode === "summary") {
      return await handleSummaryMode(req, res, body);
    }

    const token = parseBearerToken(req.headers.authorization);
    if (!token) {
      return res.status(401).json(
        makeErrorResponse({
          error: "Missing authorization token.",
          code: "MISSING_AUTH_TOKEN",
        }),
      );
    }

    await assertAdminUser(token);

    const openaiApiKey = process.env.OPENAI_API_KEY;
    if (!openaiApiKey) {
      return res.status(500).json(
        makeErrorResponse({
          error: "OpenAI 이미지 API 키가 설정되지 않았습니다.",
          code: "MISSING_OPENAI_API_KEY",
        }),
      );
    }

    const imageBase64 = String(body.imageBase64 || "").trim();
    const mimeType = String(body.mimeType || "").trim().toLowerCase();

    if (!imageBase64 || !mimeType) {
      return res.status(400).json(
        makeErrorResponse({
          error: "Image payload is empty.",
          code: "EMPTY_IMAGE_PAYLOAD",
        }),
      );
    }

    if (!allowedInputMimeTypes.has(mimeType)) {
      return res.status(400).json(
        makeErrorResponse({
          error: "Unsupported image mime type.",
          code: "UNSUPPORTED_MIME_TYPE",
          detail: `mimeType=${mimeType}`,
        }),
      );
    }

    if (!isBase64(imageBase64)) {
      return res.status(400).json(
        makeErrorResponse({
          error: "Invalid base64 image payload.",
          code: "INVALID_BASE64_PAYLOAD",
        }),
      );
    }

    if (imageBase64.length > MAX_IMAGE_BASE64_LENGTH) {
      return res.status(413).json(
        makeErrorResponse({
          error: "Image payload is too large.",
          code: "IMAGE_PAYLOAD_TOO_LARGE",
          detail: `base64Length=${imageBase64.length}, max=${MAX_IMAGE_BASE64_LENGTH}`,
        }),
      );
    }

    const output = await generateStudioImage({
      apiKey: openaiApiKey,
      imageBase64,
      mimeType,
    });

    return res.status(200).json(output);
  } catch (error) {
    if (error?.statusCode) {
      if (error.statusCode === 401) {
        return res.status(401).json(
          makeErrorResponse({
            error: "Authentication required.",
            code: "AUTH_REQUIRED",
          }),
        );
      }
      if (error.statusCode === 403) {
        return res.status(403).json(
          makeErrorResponse({
            error: "Admin access required.",
            code: "ADMIN_REQUIRED",
          }),
        );
      }
      return res.status(error.statusCode).json(
        makeErrorResponse({
          error: "Request failed.",
          code: "REQUEST_FAILED",
          detail: getErrorDetail(error),
        }),
      );
    }

    const detail = getErrorDetail(error);
    const statusCode = Number.isInteger(error?.status) ? error.status : 500;
    const explicitCode = String(error?.code || "").trim();
    const code = explicitCode
      ? explicitCode
      : statusCode === 429
        ? "OPENAI_RATE_LIMITED"
        : statusCode >= 500
          ? "OPENAI_SERVER_ERROR"
          : "OPENAI_REQUEST_FAILED";

    console.error("[book-studio] handler failure", {
      statusCode,
      code,
      detail,
      message: error?.message || "",
    });

    return res.status(statusCode).json(
      makeErrorResponse({
        error: "AI 표지 가공에 실패했습니다. 잠시 후 다시 시도해 주세요.",
        code,
        detail,
      }),
    );
  }
}
