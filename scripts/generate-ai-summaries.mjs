// 상품 AI 요약 배치 생성 — Gemini 2.5 Flash + 구글 검색 그라운딩.
//
// 설계 (2026-07-12):
//   - 실시간이 아니라 사전 생성: products.ai_summary 에 저장, 상세 페이지는 읽기만.
//   - 환각 대응: 검색으로 확인된 내용만 서술하도록 프롬프트 제한, 출처 URL을
//     ai_summary_sources 에 저장(검수용). 생성 후 어드민에서 수정 가능(후속 작업).
//   - 그라운딩 무료 쿼터(Gemini 2.5 Flash: 1,500회/일) 안에서 처리 — 818개 1일 커버.
//
// 사용법:
//   node backend/scripts/generate-ai-summaries.mjs --limit 5        # 샘플 5개
//   node backend/scripts/generate-ai-summaries.mjs                  # 미생성 전체
//   node backend/scripts/generate-ai-summaries.mjs --ids 12,34      # 특정 상품
//   node backend/scripts/generate-ai-summaries.mjs --force --ids 12 # 재생성
//
// .env.local: GEMINI_API_KEY / SUPABASE_SERVICE_ROLE_KEY (+ VITE_SUPABASE_URL은 .env)

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

function loadEnv(path) {
  const env = {};
  let text = "";
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return env;
  }
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) {
      let value = m[2].trim();
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      env[m[1]] = value;
    }
  }
  return env;
}

const env = {
  ...loadEnv(resolve(__dirname, "../../.env")),
  ...loadEnv(resolve(__dirname, "../../.env.local")),
};

const SUPABASE_URL = env.VITE_SUPABASE_URL || (env.SUPABASE_PROJECT_REF ? `https://${env.SUPABASE_PROJECT_REF}.supabase.co` : null);
const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
const GEMINI_KEY = env.GEMINI_API_KEY;
// gemini-2.5-flash는 신규 키에서 종료(404) — 3.5-flash 사용 (그라운딩 월 5,000회 무료 티어)
const MODEL = "gemini-3.5-flash";
const DELAY_MS = 1500;

if (!SUPABASE_URL || !SERVICE_KEY || !GEMINI_KEY) {
  console.error("필요 env 누락: VITE_SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / GEMINI_API_KEY");
  process.exit(1);
}

const args = process.argv.slice(2);
const getFlag = (name) => {
  const idx = args.indexOf(name);
  return idx >= 0 ? args[idx + 1] : null;
};
const limit = Number(getFlag("--limit")) || null;
const idsArg = getFlag("--ids");
const force = args.includes("--force");

const serviceHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

function buildPrompt(product) {
  const facts = [
    `- 제목: ${product.title}${product.option ? ` (${product.option})` : ""}`,
    `- 과목: ${product.subject ?? "미상"} / 유형: ${product.book_type ?? "미상"} / 출판연도: ${product.published_year ?? "미상"}`,
    `- 브랜드/출판사: ${product.brand ?? "미상"} / 강사: ${product.instructor_name ?? "미상"}`,
  ].join("\n");

  return `당신은 수능 교재 중고거래 플랫폼 '수북'의 교재 소개 작성자입니다.
아래 교재를 구글에서 검색해 실제 정보(난이도, 구성 방향, 수험생들의 평가, 추천 대상)를 확인한 뒤, 이 교재를 처음 보는 수험생에게 도움이 되는 소개를 작성하세요.

[교재 정보 — 우리 데이터베이스의 확정 사실]
${facts}

[작성 규칙]
1. 검색으로 확인된 내용만 쓰고, "~라는 평가가 많아요", "~로 알려져 있어요"처럼 근거가 검색임이 드러나게 쓰세요.
2. 검색으로 확인되지 않는 구체적 사실(목차, 문항 수, 개정판 차이 등)은 절대 언급하지 마세요.
3. 검색 결과가 부족한 교재라면 과장 없이, 이 유형의 교재를 수험생이 어떻게 활용하면 좋은지 일반적인 조언 위주로 쓰세요.
4. 한국어 존댓말로 3~4문장, 문단 하나로만. 이모지·과장 광고 문구·목록·헤더 금지.
5. 중고 매물의 상태나 가격은 언급하지 마세요 (페이지에 별도로 표시됩니다).
6. 소개 본문만 출력하세요 (제목·인사말·부연 설명 금지).`;
}

async function generateSummary(product) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
    {
      method: "POST",
      headers: { "x-goog-api-key": GEMINI_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [{ text: buildPrompt(product) }] }],
        // ⚠ camelCase 필수 — snake_case(google_search)는 조용히 무시되어 그라운딩이 안 붙음 (실측)
        tools: [{ googleSearch: {} }],
        // thinking 모델이라 사고 토큰이 예산을 잠식 → 여유 있게 (2048에선 앞/끝 잘림 실측)
        generationConfig: { temperature: 0.4, maxOutputTokens: 4096 },
      }),
    },
  );
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`Gemini ${res.status}: ${JSON.stringify(data).slice(0, 300)}`);
  }

  const candidate = data?.candidates?.[0];
  // 토큰 예산 소진(MAX_TOKENS) 등으로 잘린 응답은 불완전 — 실패로 처리해 재시도 유도
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

async function main() {
  let query = `${SUPABASE_URL}/rest/v1/products?select=id,title,option,subject,brand,book_type,published_year,instructor_name,ai_summary&order=id.asc`;
  if (idsArg) {
    query += `&id=in.(${idsArg})`;
  } else if (!force) {
    query += `&ai_summary=is.null`;
  }
  if (limit) {
    query += `&limit=${limit}`;
  }

  const listRes = await fetch(query, { headers: serviceHeaders });
  const products = await listRes.json();
  if (!Array.isArray(products)) {
    console.error("상품 조회 실패:", JSON.stringify(products).slice(0, 200));
    process.exit(1);
  }
  console.log(`대상 상품: ${products.length}개 (model=${MODEL}, force=${force})`);

  let ok = 0;
  let failed = 0;
  for (let i = 0; i < products.length; i += 1) {
    const product = products[i];
    try {
      let result;
      try {
        result = await generateSummary(product);
      } catch {
        // 일시 오류/불완전 응답은 1회 재시도
        await new Promise((r) => setTimeout(r, 2000));
        result = await generateSummary(product);
      }
      const { text, sources } = result;
      if (!text || text.length < 40) {
        throw new Error(`생성 결과가 너무 짧음 (${text?.length ?? 0}자)`);
      }
      const patchRes = await fetch(`${SUPABASE_URL}/rest/v1/products?id=eq.${product.id}`, {
        method: "PATCH",
        headers: { ...serviceHeaders, Prefer: "return=minimal" },
        body: JSON.stringify({
          ai_summary: text,
          ai_summary_sources: sources,
          ai_summary_generated_at: new Date().toISOString(),
        }),
      });
      if (!patchRes.ok) {
        throw new Error(`저장 실패 HTTP ${patchRes.status}`);
      }
      ok += 1;
      console.log(`[${i + 1}/${products.length}] #${product.id} ${product.title.slice(0, 30)} — OK (${text.length}자, 출처 ${sources.length})`);
    } catch (err) {
      failed += 1;
      console.error(`[${i + 1}/${products.length}] #${product.id} 실패: ${String(err.message).slice(0, 200)}`);
    }
    if (i < products.length - 1) {
      await new Promise((r) => setTimeout(r, DELAY_MS));
    }
  }
  console.log(`완료: 성공 ${ok} / 실패 ${failed}`);
}

main().catch((err) => {
  console.error("실행 실패:", err);
  process.exit(1);
});
