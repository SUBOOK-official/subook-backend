import { createClient } from "@supabase/supabase-js";
import { parsePerformanceQuery, loadGaPerformance, loadMetaPerformance, optionalProvider } from "../_lib/performance.js";

async function authorize(token) {
  const url = process.env.SUPABASE_ADMIN_URL || process.env.VITE_SUPABASE_ADMIN_URL;
  const key = process.env.SUPABASE_ADMIN_ANON_KEY || process.env.VITE_SUPABASE_ADMIN_ANON_KEY;
  if (!url || !key) throw Object.assign(new Error("서버 연결 설정을 확인해주세요."), { status: 503 });
  const client = createClient(url, key, { global: { headers: { Authorization: `Bearer ${token}` },
    fetch: (input, init) => fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(8_000) }) },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(token);
  if (error || !data?.user) throw Object.assign(new Error("로그인이 필요합니다."), { status: 401 });
  const admin = await client.rpc("is_admin_user").abortSignal(AbortSignal.timeout(8_000));
  if (admin.error || admin.data !== true) throw Object.assign(new Error("관리자만 조회할 수 있습니다."), { status: 403 });
}

export function createPerformanceHandler({ checkAdmin = authorize, loadGa = loadGaPerformance, loadMeta = loadMetaPerformance } = {}) {
  return async function handler(req, res) {
    res.setHeader("Cache-Control", "private, no-store");
    if (req.method !== "GET") { res.setHeader("Allow", "GET"); return res.status(405).json({ error: "GET 요청만 허용됩니다.", code: 405 }); }
    const token = String(req.headers.authorization || "").match(/^Bearer\s+(\S+)$/i)?.[1];
    if (!token) return res.status(401).json({ error: "로그인이 필요합니다.", code: 401 });
    try { await checkAdmin(token); } catch (error) {
      const code = [401, 403, 503].includes(error.status) ? error.status : 503;
      return res.status(code).json({ error: code === 401 ? "로그인이 필요합니다." : code === 403 ? "관리자만 조회할 수 있습니다." : "관리자 인증을 확인하지 못했습니다.", code });
    }
    let range;
    try { range = parsePerformanceQuery(req.query); } catch {
      return res.status(400).json({ error: "조회 기간 또는 광고 필터를 확인해주세요.", code: 400 });
    }
    const [ga, meta] = await Promise.all([
      optionalProvider(() => loadGa(range), "GA4"), optionalProvider(() => loadMeta(range), "Meta"),
    ]);
    return res.status(200).json({ from: range.from, to: range.to, ga, meta });
  };
}

export default createPerformanceHandler();
