import { createClient } from "@supabase/supabase-js";

// 표지 스캔 인식 API (2026-08-24) — 검수대에서 표지 사진 한 장으로
// "이 책이 카탈로그의 어떤 상품인지" 후보를 찾아준다.
// 파이프라인: Gemini 구조화 추출(표지에 인쇄된 텍스트만) → products 전량 로컬 매칭 → top5.
//
// ⚠️ Gemini는 REST(fetch) 직접 호출 — @google/genai SDK 금지 (book-studio.js 상단 주석 참조).
// ⚠️ 추출 프롬프트·매칭 로직은 tools/cover-scan-prototype(창고 실측용)과 동일하게 유지할 것.
//    실측 CSV로 튜닝하면 양쪽에 같이 반영해야 결과가 일치한다.

const MODEL_ID = process.env.GEMINI_COVER_SCAN_MODEL || "gemini-3.5-flash";
const GEMINI_TIMEOUT_MS = 60_000;
const MAX_IMAGE_BASE64_LENGTH = 4_000_000; // Vercel 요청 본문 4.5MB 상한 고려
const CATALOG_TTL_MS = 5 * 60_000;
const allowedInputMimeTypes = new Set(["image/jpeg", "image/png", "image/webp"]);

function makeErrorResponse({ error, code, detail }) {
  const payload = {
    error: String(error || "Request failed."),
    code: String(code || "UNKNOWN"),
  };
  if (detail) payload.detail = String(detail);
  return payload;
}

function getSupabaseConfig() {
  const url = process.env.SUPABASE_ADMIN_URL || process.env.VITE_SUPABASE_ADMIN_URL;
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

// ── 카탈로그 (products 전량, anon 공개 읽기) — warm 인스턴스 5분 캐시 ──────
const CATALOG_COLUMNS =
  "id,title,option,subject,brand,book_type,published_year,instructor_name,cover_image_url";
let catalogCache = { rows: [], fetchedAt: 0 };

async function loadCatalog() {
  if (catalogCache.rows.length > 0 && Date.now() - catalogCache.fetchedAt < CATALOG_TTL_MS) {
    return catalogCache.rows;
  }
  const { url, anonKey } = getSupabaseConfig();
  const pageSize = 1000;
  let from = 0;
  const all = [];
  for (;;) {
    const res = await fetch(
      `${url}/rest/v1/products?select=${CATALOG_COLUMNS}&order=id.asc`,
      {
        headers: {
          apikey: anonKey,
          Authorization: `Bearer ${anonKey}`,
          "Range-Unit": "items",
          Range: `${from}-${from + pageSize - 1}`,
        },
      },
    );
    if (!res.ok) {
      const error = new Error(`CATALOG_FETCH_FAILED_${res.status}`);
      error.statusCode = 502;
      throw error;
    }
    const rows = await res.json();
    all.push(...rows);
    if (rows.length < pageSize) break;
    from += pageSize;
  }
  catalogCache = { rows: all, fetchedAt: Date.now() };
  return all;
}

// ── 텍스트 정규화 + bigram Dice 유사도 (프로토타입과 동일) ─────────────────
function normalize(input) {
  return (
    String(input ?? "")
      .normalize("NFKC") // 로마 숫자 Ⅰ/Ⅱ 등은 NFKC가 라틴 i/ii로 풀어준다
      .toLowerCase()
      .replace(/[\s\-_·.,:;()\[\]{}/\\'"!?+&*~｜|]/g, "")
      // 한글 뒤에 붙은 로마자 과목 표기 → 숫자 ("지구과학i"→"지구과학1", "수학ii"→"수학2")
      .replace(/([가-힣])iv(?![a-z])/g, "$14")
      .replace(/([가-힣])iii(?![a-z])/g, "$13")
      .replace(/([가-힣])ii(?![a-z])/g, "$12")
      .replace(/([가-힣])i(?![a-z])/g, "$11")
  );
}

function bigrams(s) {
  if (s.length < 2) return s ? [s] : [];
  const grams = [];
  for (let i = 0; i < s.length - 1; i += 1) grams.push(s.slice(i, i + 2));
  return grams;
}

function diceSimilarity(a, b) {
  const ga = bigrams(a);
  const gb = bigrams(b);
  if (!ga.length || !gb.length) return 0;
  const counts = new Map();
  for (const g of ga) counts.set(g, (counts.get(g) || 0) + 1);
  let overlap = 0;
  for (const g of gb) {
    const c = counts.get(g) || 0;
    if (c > 0) {
      overlap += 1;
      counts.set(g, c - 1);
    }
  }
  return (2 * overlap) / (ga.length + gb.length);
}

// 매칭 점수: 제목 유사도가 몸통, 강사/연도/브랜드/과목/옵션은 가감점
function scoreProduct(extracted, product) {
  const extTitle = normalize(extracted.title);
  const extInstructor = normalize(extracted.instructor_name);
  const extBrand = normalize(extracted.brand);
  const extSubject = normalize(extracted.subject);
  const extOption = normalize(extracted.option);
  const extYear = String(extracted.published_year || "").match(/\d{4}/)?.[0] || "";

  const prodTitle = normalize(product.title);
  const prodInstructor = normalize(product.instructor_name);
  const prodBrand = normalize(product.brand);
  const prodSubject = normalize(product.subject);
  const prodOption = normalize(product.option);
  const prodYear = product.published_year ? String(product.published_year) : "";

  // 제목: 표기 관례 차이(강사명·과목이 제목에 붙거나 빠지는 경우)를 조합 최대값으로 흡수
  const titleSim = Math.max(
    diceSimilarity(extTitle, prodTitle),
    extSubject ? diceSimilarity(extTitle + extSubject, prodTitle) : 0,
    extInstructor ? diceSimilarity(extInstructor + extTitle, prodTitle) : 0,
    extInstructor && extSubject
      ? diceSimilarity(extInstructor + extTitle + extSubject, prodTitle)
      : 0,
    prodInstructor ? diceSimilarity(extTitle, prodInstructor + prodTitle) : 0,
  );

  let score = 0.62 * titleSim;
  const reasons = [`제목 ${(titleSim * 100).toFixed(0)}%`];

  if (extSubject && extSubject.length >= 2 && prodTitle.includes(extSubject)) {
    score += 0.08;
    reasons.push("과목=제목 포함");
  }

  if (extInstructor && prodInstructor) {
    if (
      extInstructor === prodInstructor ||
      extInstructor.includes(prodInstructor) ||
      prodInstructor.includes(extInstructor)
    ) {
      score += 0.18;
      reasons.push("강사 일치");
    } else {
      score -= 0.08;
      reasons.push("강사 불일치");
    }
  }

  if (extYear && prodYear) {
    if (extYear === prodYear) {
      score += 0.1;
      reasons.push("연도 일치");
    } else {
      score -= 0.06;
      reasons.push(`연도 다름(${extYear}↔${prodYear})`);
    }
  }

  if (extBrand && prodBrand && (extBrand.includes(prodBrand) || prodBrand.includes(extBrand))) {
    score += 0.06;
    reasons.push("브랜드 일치");
  }

  if (extSubject && prodSubject) {
    if (
      extSubject === prodSubject ||
      extSubject.includes(prodSubject) ||
      prodSubject.includes(extSubject)
    ) {
      score += 0.04;
      reasons.push("과목 일치");
    } else {
      score -= 0.02;
    }
  }

  if (extOption && prodOption) {
    const optionSim = diceSimilarity(extOption, prodOption);
    if (optionSim > 0.5) {
      score += 0.06;
      reasons.push("옵션 유사");
    }
  }

  return { score: Math.max(0, Math.min(1, score)), reasons };
}

function matchCandidates(extracted, catalog, limit = 5) {
  const scored = catalog.map((product) => {
    const { score, reasons } = scoreProduct(extracted, product);
    return { product, score, reasons };
  });
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, limit).map(({ product, score, reasons }) => ({
    id: product.id,
    title: product.title,
    option: product.option,
    subject: product.subject,
    brand: product.brand,
    book_type: product.book_type,
    published_year: product.published_year,
    instructor_name: product.instructor_name,
    cover_image_url: product.cover_image_url,
    score: Number(score.toFixed(4)),
    reasons,
  }));
}

// ── Gemini 구조화 추출 ─────────────────────────────────────────────────────
const EXTRACTION_PROMPT = `
사진 속 한국 학습 교재(수능/내신/인강 교재)의 표지에서 서지 정보를 추출한다.

규칙:
- 표지에 인쇄된 내용만 근거로 한다. 보이지 않는 값은 추측하지 말고 빈 문자열 ""로 둔다.
- title: 교재의 핵심 제목. 시리즈명 포함, 마케팅 슬로건·수식 문구는 제외.
- option: 분권/구성 표기 (예: 1권, 2권, 상, 하, 워크북, 해설편, 문제편). 없으면 "".
- instructor_name: 강사 또는 저자 이름. 없으면 "".
- brand: 출판사·학원·브랜드명. 로고가 영문이어도 한글 정식 명칭으로 쓴다
  (예: 로고 "sdij" → "시대인재", 그 외 대성마이맥, 메가스터디, EBS 등). 없으면 "".
- published_year: 대상 연도 4자리. "2027 수능 대비"→"2027", "2026학년도"→"2026". 없으면 "".
- subject: 과목 표기 (예: 물리학1, 수학1, 국어, 영어, 사회문화). 없으면 "".
- raw_text: 표지에서 읽은 주요 텍스트를 큰 글자 순서대로 최대 10줄.
`.trim();

const EXTRACTION_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    option: { type: "string" },
    instructor_name: { type: "string" },
    brand: { type: "string" },
    published_year: { type: "string" },
    subject: { type: "string" },
    raw_text: { type: "array", items: { type: "string" } },
  },
  required: [
    "title",
    "option",
    "instructor_name",
    "brand",
    "published_year",
    "subject",
    "raw_text",
  ],
};

async function extractFromCover({ apiKey, imageBase64, mimeType }) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), GEMINI_TIMEOUT_MS);
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
                { text: EXTRACTION_PROMPT },
                { inlineData: { data: imageBase64, mimeType } },
              ],
            },
          ],
          generationConfig: {
            responseMimeType: "application/json",
            responseSchema: EXTRACTION_SCHEMA,
          },
        }),
        signal: controller.signal,
      },
    );
  } catch (error) {
    if (error?.name === "AbortError") {
      const timeoutError = new Error(`Model response exceeded ${GEMINI_TIMEOUT_MS}ms.`);
      timeoutError.statusCode = 504;
      timeoutError.code = "GEMINI_TIMEOUT";
      throw timeoutError;
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }

  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(payload?.error?.message || `Gemini HTTP ${response.status}`);
    error.statusCode = response.status >= 500 ? 502 : response.status;
    error.code = "GEMINI_ERROR";
    throw error;
  }

  const text =
    payload?.candidates?.[0]?.content?.parts?.map((part) => part?.text || "").join("") || "";
  const usage = payload?.usageMetadata || {};

  let extracted;
  try {
    extracted = JSON.parse(text);
  } catch (_parseError) {
    const error = new Error("GEMINI_INVALID_JSON");
    error.statusCode = 502;
    error.code = "GEMINI_INVALID_JSON";
    throw error;
  }

  return {
    extracted,
    usage: {
      promptTokens: usage.promptTokenCount ?? null,
      outputTokens: usage.candidatesTokenCount ?? null,
      thoughtsTokens: usage.thoughtsTokenCount ?? null,
      totalTokens: usage.totalTokenCount ?? null,
    },
  };
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res
      .status(405)
      .json(makeErrorResponse({ error: "Method not allowed.", code: "METHOD_NOT_ALLOWED" }));
  }

  const startedAt = Date.now();
  try {
    let body = {};
    try {
      body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : req.body || {};
    } catch (_parseError) {
      return res
        .status(400)
        .json(makeErrorResponse({ error: "Invalid JSON body.", code: "INVALID_JSON_BODY" }));
    }

    const token = parseBearerToken(req.headers.authorization);
    if (!token) {
      return res
        .status(401)
        .json(makeErrorResponse({ error: "Missing authorization token.", code: "MISSING_AUTH_TOKEN" }));
    }
    await assertAdminUser(token);

    const geminiApiKey = getGeminiApiKey();
    if (!geminiApiKey) {
      return res
        .status(500)
        .json(makeErrorResponse({ error: "Gemini API key missing.", code: "GEMINI_KEY_MISSING" }));
    }

    const imageBase64 = String(body.imageBase64 || "");
    const mimeType = String(body.mimeType || "image/jpeg");
    if (!imageBase64 || !isBase64(imageBase64)) {
      return res
        .status(400)
        .json(makeErrorResponse({ error: "imageBase64 is required.", code: "INVALID_IMAGE" }));
    }
    if (imageBase64.length > MAX_IMAGE_BASE64_LENGTH) {
      return res
        .status(413)
        .json(makeErrorResponse({ error: "Image too large.", code: "IMAGE_TOO_LARGE" }));
    }
    if (!allowedInputMimeTypes.has(mimeType)) {
      return res
        .status(400)
        .json(makeErrorResponse({ error: "Unsupported image type.", code: "UNSUPPORTED_MIME" }));
    }

    const [catalog, extraction] = await Promise.all([
      loadCatalog(),
      extractFromCover({ apiKey: geminiApiKey, imageBase64, mimeType }),
    ]);

    const candidates = matchCandidates(extraction.extracted, catalog, 5);

    return res.status(200).json({
      ok: true,
      model: MODEL_ID,
      extracted: extraction.extracted,
      candidates,
      usage: extraction.usage,
      elapsedMs: Date.now() - startedAt,
    });
  } catch (error) {
    const statusCode = error?.statusCode || 500;
    return res.status(statusCode).json(
      makeErrorResponse({
        error:
          statusCode === 401
            ? "Unauthorized."
            : statusCode === 403
              ? "Admin access required."
              : error?.message || "Cover scan failed.",
        code: error?.code || (statusCode === 401 ? "UNAUTHORIZED" : statusCode === 403 ? "FORBIDDEN" : "COVER_SCAN_FAILED"),
      }),
    );
  }
}
