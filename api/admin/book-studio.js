import { createClient } from "@supabase/supabase-js";

// ⚠️ @google/genai SDK를 쓰지 말 것 (2026-07-23 확인):
// Vercel의 ESM→CJS 함수 컴파일이 이 패키지만 번들에 인라인하지 못해, 배포 후
// "Cannot find module '@google/genai/dist/node/index.cjs'"로 함수가 부팅조차 못 했다
// (7/20 출시 이후 변환 성공 0건의 1차 원인 — 런타임 로그로 확정). Gemini는 아래처럼
// REST(fetch)로 직접 호출한다. 요청/응답 스키마는 SDK와 동일 (camelCase).

// ⚠️ MODEL_ID는 Google AI Studio에서 실제 사용 가능한 모델로 설정.
// 환경변수로 외부에서 override 가능 — production에서 invalid model 사고 방지용.
// 기본값은 GA 모델 gemini-3.1-flash-image (2026-07-23 ListModels·실생성 검증,
// preview 모델은 예고 없이 폐기될 수 있어 GA 사용). imageSize 1K/2K/4K 지원.
//
// ── mode: "summary" (2026-08-03 추가) ────────────────────────────────
// 이 함수는 표지 스튜디오 변환 외에 상품 AI 요약 단건 생성도 겸한다
// (body.mode === "summary" 분기, 아래 handleSummaryMode).
// 별도 파일로 두지 않은 이유: 구현 당시(2026-08-03) Vercel Hobby 함수 12개 상한에
// 도달해 13번째 함수 추가 시 배포가 거부됐음. 같은 Gemini 호출 계열이라 여기 통합.
// (2026-08-04 Pro 전환으로 상한은 풀렸지만, DB 트리거가 이 URL을 바라보고 있고
//  동작에 문제없어 구조는 유지 — 분리하려면 migration의 URL도 함께 바꿀 것.)
// 호출 경로: products INSERT DB 트리거 + pg_cron 스위퍼(pg_net, body.token 인증,
// migration 20260804031500) / 수동 Bearer(CRON_SECRET·service key).
// 대량 백필은 여전히 backend/scripts/generate-ai-summaries.mjs (GitHub Actions).
const MODEL_ID = process.env.GEMINI_MODEL_ID || "gemini-3.1-flash-image";
const GEMINI_PRIMARY_IMAGE_SIZE = "2K";
const GEMINI_FALLBACK_IMAGE_SIZE = "1K";
const GEMINI_PRIMARY_TIMEOUT_MS = 150_000;
const GEMINI_FALLBACK_TIMEOUT_MS = 90_000;

const SYSTEM_PROMPT = `
Using the provided image of the book as the main subject:
Create a professional, ultra-high-resolution product photo for online sales featuring only this single book.

Requirements (must be strictly followed):
1. The book in the center must be reproduced exactly as in the provided reference image (maintain same cover design, text, colors, and proportions).
2. Text on the cover must be perfectly sharp and fully legible.
3. Replace the background with a clean, light gray background (neutral, studio-style, no patterns).
4. Layout: horizontal composition, with generous empty margins on all sides.
5. Lighting: Soft, even, professional studio lighting (no harsh shadows).
6. The book should appear flat and well-aligned.
7. Output quality: Photorealistic, 4K quality, look like a premium bestseller photo.
`.trim();

const MAX_IMAGE_BASE64_LENGTH = 6_000_000;
// ⚠ Vercel 함수는 요청/응답 본문 모두 4.5MB가 상한이고, 초과하면 우리 코드가 아니라
// 플랫폼이 413(FUNCTION_PAYLOAD_TOO_LARGE)으로 끊는다 — 클라이언트에는 JSON이 아닌
// 에러 페이지가 내려와 "원인 불명 실패"로 보인다. 2K 결과가 상한에 걸리면 1K로 재생성해
// 응답을 줄인다(아래 generateStudioImageWithFallback). JSON 래퍼 여유를 두고 4.2MB에서 컷.
// 출처: https://vercel.com/docs/functions/limitations#request-body-size
const MAX_OUTPUT_BASE64_LENGTH = 4_200_000;
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

function getImageOutput(response) {
  const parts = response?.candidates?.[0]?.content?.parts || [];
  for (const part of parts) {
    if (part?.inlineData?.data) {
      return {
        imageBase64: part.inlineData.data,
        mimeType: part.inlineData.mimeType || "image/png",
      };
    }
  }

  if (response?.data) {
    return { imageBase64: response.data, mimeType: "image/png" };
  }

  return null;
}

// Gemini generateContent REST 직접 호출 — AbortController로 실제 요청까지 취소.
// (2026-07-23 로컬 검증: 동일 페이로드로 2K 이미지 17초 생성 성공)
async function requestGeminiImage({ apiKey, imageBase64, mimeType, imageSize, timeoutMs }) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:generateContent`,
      {
        method: "POST",
        headers: { "x-goog-api-key": apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [
            {
              parts: [
                { text: SYSTEM_PROMPT },
                { inlineData: { data: imageBase64, mimeType } },
              ],
            },
          ],
          generationConfig: {
            responseModalities: ["IMAGE"],
            imageConfig: {
              aspectRatio: "1:1",
              imageSize,
            },
          },
        }),
        signal: controller.signal,
      },
    );
  } catch (error) {
    if (error?.name === "AbortError") {
      throw makeTimeoutError(timeoutMs);
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }

  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(payload?.error?.message || `Gemini HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return payload;
}

function isRetryableGeminiError(error) {
  const status = Number(error?.status);
  return (
    error?.code === "GEMINI_TIMEOUT" ||
    status === 429 ||
    Number.isNaN(status) ||
    status >= 500
  );
}

async function generateStudioImageWithFallback({ apiKey, imageBase64, mimeType }) {
  const attempts = [
    {
      label: "primary",
      imageSize: GEMINI_PRIMARY_IMAGE_SIZE,
      timeoutMs: GEMINI_PRIMARY_TIMEOUT_MS,
    },
    {
      label: "fallback",
      imageSize: GEMINI_FALLBACK_IMAGE_SIZE,
      timeoutMs: GEMINI_FALLBACK_TIMEOUT_MS,
    },
  ];

  let lastError = null;

  for (let index = 0; index < attempts.length; index += 1) {
    const attempt = attempts[index];
    const isLastAttempt = index === attempts.length - 1;

    try {
      const response = await requestGeminiImage({
        apiKey,
        imageBase64,
        mimeType,
        imageSize: attempt.imageSize,
        timeoutMs: attempt.timeoutMs,
      });

      const output = getImageOutput(response);
      if (!output) {
        const emptyError = new Error("Model response did not contain an image.");
        emptyError.code = "MODEL_EMPTY_IMAGE_OUTPUT";
        emptyError.status = 502;
        emptyError.detail = String(response?.text || "");
        throw emptyError;
      }

      // 응답 본문 상한 초과분은 더 작은 해상도로 재생성해서 회수한다.
      if (output.imageBase64.length > MAX_OUTPUT_BASE64_LENGTH) {
        const tooLargeError = new Error(
          `Generated image exceeds the response body limit (base64=${output.imageBase64.length}).`,
        );
        tooLargeError.code = "STUDIO_OUTPUT_TOO_LARGE";
        tooLargeError.status = 502;
        throw tooLargeError;
      }

      return output;
    } catch (error) {
      lastError = error;
      console.error("[book-studio] Gemini generation attempt failed", {
        attempt: attempt.label,
        imageSize: attempt.imageSize,
        timeoutMs: attempt.timeoutMs,
        code: error?.code || "",
        status: error?.status || "",
        message: error?.message || "",
      });

      const recoverable =
        isRetryableGeminiError(error) ||
        error?.code === "STUDIO_OUTPUT_TOO_LARGE" ||
        error?.code === "MODEL_EMPTY_IMAGE_OUTPUT";

      if (isLastAttempt || !recoverable) {
        throw error;
      }
    }
  }

  throw lastError || new Error("GEMINI_GENERATION_FAILED");
}

// ── 상품 AI 요약 단건 생성 (mode: "summary") ─────────────────────────
// 생성 규칙은 backend/scripts/generate-ai-summaries.mjs의 검증된 로직 이식:
// gemini-3.5-flash + 검색 그라운딩(camelCase googleSearch 필수 — snake_case는
// 조용히 무시됨), thinking 파트 제외, maxOutputTokens 4096(2048은 잘림),
// finishReason!=="STOP" 실패 처리, 출처 0이면 1회 재시도, option 미포함(분권 앵커링 방지).

const SUMMARY_MODEL_ID = process.env.GEMINI_SUMMARY_MODEL_ID || "gemini-3.5-flash";
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
먼저 반드시 구글 검색을 실행해 이 교재의 실제 정보(난이도, 구성 방향, 수험생들의 평가, 추천 대상)를 확인한 뒤, 이 교재를 처음 보는 수험생에게 도움이 되는 소개를 작성하세요. 검색 없이 기억만으로 쓰지 마세요.

[교재 정보 — 우리 데이터베이스의 확정 사실]
${facts}

[작성 규칙]
1. 이 상품은 같은 교재의 여러 분권·옵션(예: 수학1+수학2 / 미적분, 회차별)으로 판매될 수 있습니다. 특정 분권이 아니라 교재(시리즈) 전체를 일반화해서 소개하고, 분권명을 제목처럼 확정해 쓰지 마세요.
2. 검색으로 확인된 내용만 쓰고, "~라는 평가가 많아요", "~로 알려져 있어요"처럼 근거가 검색임이 드러나게 쓰세요.
3. 검색으로 확인되지 않는 구체적 사실(목차, 문항 수, 개정판 차이 등)은 절대 언급하지 마세요.
4. 검색 결과가 부족한 교재라면 과장 없이, 이 유형의 교재를 수험생이 어떻게 활용하면 좋은지 일반적인 조언 위주로 쓰세요.
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
          generationConfig: { temperature: 0.4, maxOutputTokens: 4096 },
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

    const geminiApiKey = getGeminiApiKey();
    if (!geminiApiKey) {
      return res.status(500).json(
        makeErrorResponse({
          error: "Server is missing GEMINI_API_KEY.",
          code: "MISSING_GEMINI_API_KEY",
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

    // 이미지 추출·응답 크기 검증까지 마친 결과를 받는다(해상도 폴백 포함).
    const output = await generateStudioImageWithFallback({
      apiKey: geminiApiKey,
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
        ? "GEMINI_RATE_LIMITED"
        : statusCode >= 500
          ? "GEMINI_SERVER_ERROR"
          : "GEMINI_REQUEST_FAILED";

    console.error("[book-studio] handler failure", {
      statusCode,
      code,
      detail,
      message: error?.message || "",
    });

    return res.status(statusCode).json(
      makeErrorResponse({
        error: "Failed to generate studio image.",
        code,
        detail,
      }),
    );
  }
}
