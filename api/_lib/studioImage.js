// 표지 가공 전용. 상품 AI 설명·교재 인식은 기존 Gemini 경로를 사용한다.
// 공식 명세: https://developers.openai.com/api/reference/resources/images/methods/edit
export const STUDIO_MODEL = "gpt-image-2.5-sunburst";
export const STUDIO_QUALITY = "medium";
export const STUDIO_SIZE = "2048x2048";
const MAX_OUTPUT_BASE64_LENGTH = 4_200_000;
const TOTAL_TIMEOUT_MS = 200_000;
const ATTEMPT_TIMEOUT_MS = 150_000;

const STUDIO_PROMPT = `
Edit the provided real textbook cover into ONE faithful ecommerce product photo.
This is source-preserving photography, not a cover redesign.
GEOMETRY LOCK — the input has already been oriented by a pixel-only rotation.
Do NOT rotate it again or infer a different book shape from its title or category.
Treat the entire visible cover as one rigid, flat rectangle with fixed proportions.
Keep its measured width-to-height ratio EXACTLY as shown in this input.
There is NO preset or target aspect ratio. Use this particular input's proportions.
The preprocessing rotation only swaps the original width W and height H into H and W;
it never changes either side's length. Keep that exact resulting geometry.
The square OUTPUT CANVAS is only background; it must NEVER make the cover square
or wider, shorter, longer or narrower. Only uniform scaling is allowed: multiply
both cover dimensions by the SAME factor. Preserve all four corners and edges.
Do not stretch, squeeze, warp, crop, fold, split, redraw or reconstruct the cover.
Do not rearrange the artwork or reflow text to fit a conventional textbook shape.
Preserve the exact relative positions and proportions of all printed elements.
If the cover does not fill the square canvas, leave background space around it.
Show this single book centered in a square image, straight and front-facing,
with its original proportions and full cover visible, ample light neutral gray
background margins on every side, soft even studio lighting and a subtle contact shadow.
Remove only scanner surroundings outside the cover; do not change the cover geometry.
The original cover is authoritative: preserve its exact artwork, colors, layout,
typography, logos, every Korean character, every number, year, edition and volume.
Preserve intentional graphical effects and fractured/glitch-styled letters as printed.
Do not translate, retype in a new font, simplify, reconstruct or invent unreadable text.
Do not add text, objects, a spine or pages that are not visible in the source.
Preserve actual physical wear and marks exactly: do not add, exaggerate, hide or repair wear.
Change only external background, placement and evenness of lighting. Geometry preservation wins over styling.
`.trim();

function studioError(message, code, status = 502) {
  return Object.assign(new Error(message), { code, status });
}

function timeoutError() {
  return studioError("이미지 생성 시간이 초과되었습니다. 잠시 후 결과를 확인하고 다시 시도해 주세요.", "OPENAI_TIMEOUT", 504);
}

async function requestImage({ apiKey, imageBase64, mimeType, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const form = new FormData();
    const extension = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" }[mimeType];
    form.append("model", STUDIO_MODEL);
    form.append("quality", STUDIO_QUALITY);
    form.append("size", STUDIO_SIZE);
    form.append("n", "1");
    // PNG는 실측 약 6MB로 Vercel 응답 한도(4.5MB)를 초과한다.
    // 재생성 대신 처음부터 JPEG로 요청해 2K 해상도를 유지한다.
    form.append("output_format", "jpeg");
    form.append("output_compression", "90");
    form.append("prompt", STUDIO_PROMPT);
    form.append("image", new Blob([Buffer.from(imageBase64, "base64")], { type: mimeType }), `cover.${extension}`);
    const response = await fetch("https://api.openai.com/v1/images/edits", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
      signal: controller.signal,
    });
    // 응답 본문을 다 읽을 때까지 타임아웃을 유지한다.
    const payload = await response.json().catch((error) => {
      if (controller.signal.aborted) throw error;
      return null;
    });
    if (!response.ok) {
      const providerCode = String(payload?.error?.code || "");
      const billingError = /insufficient_quota|billing|credit/i.test(providerCode);
      const error = billingError
        ? studioError("OpenAI API 크레딧 또는 사용 한도를 확인해 주세요.", "OPENAI_BILLING_REQUIRED", 503)
        : response.status === 401 || response.status === 403
          ? studioError("OpenAI 이미지 API 키 또는 접근 권한을 확인해 주세요.", "OPENAI_AUTH_FAILED")
          : response.status === 429
            ? studioError("이미지 생성 요청이 몰리고 있습니다. 잠시 후 다시 시도해 주세요.", "OPENAI_RATE_LIMITED", 429)
            : studioError("이미지를 생성하지 못했습니다. 사진을 확인하고 다시 시도해 주세요.", "OPENAI_REQUEST_FAILED");
      error.retryable = !billingError && (response.status === 429 || response.status >= 500);
      const retrySeconds = Number(response.headers.get("retry-after"));
      error.retryDelayMs = Number.isFinite(retrySeconds) && retrySeconds > 0
        ? Math.min(5000, retrySeconds * 1000) : 1000;
      error.providerStatus = response.status;
      throw error;
    }
    return { payload, requestId: response.headers.get("x-request-id") };
  } catch (error) {
    if (controller.signal.aborted) throw timeoutError();
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export async function generateStudioImage({ apiKey, imageBase64, mimeType }) {
  const startedAt = Date.now();
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const remaining = TOTAL_TIMEOUT_MS - (Date.now() - startedAt);
    if (remaining <= 0) throw timeoutError();
    try {
      const { payload, requestId } = await requestImage({
        apiKey, imageBase64, mimeType,
        timeoutMs: Math.min(ATTEMPT_TIMEOUT_MS, remaining),
      });
      const output = payload?.data?.[0]?.b64_json;
      if (typeof output !== "string" || !output || !/^[A-Za-z0-9+/]+={0,2}$/.test(output)) {
        throw studioError("생성 결과에 이미지가 없습니다. 다시 시도해 주세요.", "MODEL_EMPTY_IMAGE_OUTPUT");
      }
      if (output.length > MAX_OUTPUT_BASE64_LENGTH) {
        throw studioError("생성 이미지 용량이 서버 제한을 넘었습니다. 더 작은 원본으로 다시 시도해 주세요.", "STUDIO_OUTPUT_TOO_LARGE");
      }
      const bytes = Buffer.from(output, "base64");
      if (bytes.length < 3 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
        throw studioError("생성 이미지 형식이 올바르지 않습니다. 다시 시도해 주세요.", "INVALID_STUDIO_IMAGE");
      }
      console.log("[book-studio] OpenAI image generated", {
        model: STUDIO_MODEL, quality: STUDIO_QUALITY, size: STUDIO_SIZE,
        requestId, elapsedMs: Date.now() - startedAt, attempt: attempt + 1,
        usage: payload.usage || null,
      });
      return { imageBase64: output, mimeType: "image/jpeg" };
    } catch (error) {
      // 명시적 일시 오류만 한 번 재시도. 시간 초과·연결 단절·완성 응답 검증 실패는
      // 이미 과금됐을 수 있으므로 자동으로 다시 생성하지 않는다.
      if (!error.retryable || attempt === 1) throw error;
      console.warn("[book-studio] OpenAI retry", { code: error.code, status: error.providerStatus });
      await new Promise((resolve) => setTimeout(resolve, error.retryDelayMs));
    }
  }
  throw studioError("이미지 생성에 실패했습니다. 다시 시도해 주세요.", "OPENAI_REQUEST_FAILED");
}
