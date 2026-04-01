import { GoogleGenAI } from "@google/genai";
import { createClient } from "@supabase/supabase-js";

const MODEL_ID = "gemini-3.1-flash-image-preview";
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

async function withTimeout(promise, timeoutMs) {
  let timeoutId = null;

  const timeoutPromise = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      reject(makeTimeoutError(timeoutMs));
    }, timeoutMs);
  });

  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    if (timeoutId) {
      clearTimeout(timeoutId);
    }
  }
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

async function requestGeminiImage({ ai, imageBase64, mimeType, imageSize }) {
  return ai.models.generateContent({
    model: MODEL_ID,
    contents: [
      { text: SYSTEM_PROMPT },
      { inlineData: { data: imageBase64, mimeType } },
    ],
    config: {
      responseModalities: ["IMAGE"],
      imageConfig: {
        aspectRatio: "1:1",
        imageSize,
      },
    },
  });
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

async function generateStudioImageWithFallback({ ai, imageBase64, mimeType }) {
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

  for (const attempt of attempts) {
    try {
      return await withTimeout(
        requestGeminiImage({
          ai,
          imageBase64,
          mimeType,
          imageSize: attempt.imageSize,
        }),
        attempt.timeoutMs,
      );
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

      if (!isRetryableGeminiError(error)) {
        throw error;
      }
    }
  }

  throw lastError || new Error("GEMINI_GENERATION_FAILED");
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

    const ai = new GoogleGenAI({ apiKey: geminiApiKey });
    const response = await generateStudioImageWithFallback({
      ai,
      imageBase64,
      mimeType,
    });

    const output = getImageOutput(response);
    if (!output) {
      return res.status(502).json({
        ...makeErrorResponse({
          error: "Model response did not contain an image.",
          code: "MODEL_EMPTY_IMAGE_OUTPUT",
          detail: response?.text || "",
        }),
      });
    }

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
