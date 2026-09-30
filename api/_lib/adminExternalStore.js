import { createClient } from "@supabase/supabase-js";
import { problem } from "./metaAds.js";

function options(token) {
  return {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      ...(token ? { headers: { Authorization: `Bearer ${token}` } } : {}),
      fetch: (input, init) =>
        fetch(input, {
          ...init,
          signal: init?.signal ?? AbortSignal.timeout(10000),
        }),
    },
  };
}
export async function authorizeAdmin(token, env = process.env) {
  const url = env.SUPABASE_ADMIN_URL || env.VITE_SUPABASE_ADMIN_URL;
  const key = env.SUPABASE_ADMIN_ANON_KEY || env.VITE_SUPABASE_ADMIN_ANON_KEY;
  if (!url || !key) throw problem("서버 인증 연결을 확인해 주세요.", 503);
  const client = createClient(url, key, options(token));
  const { data, error } = await client.auth.getUser(token);
  if (error || !data.user) throw problem("다시 로그인해 주세요.", 401);
  const admin = await client.rpc("is_admin_user");
  if (admin.error || admin.data !== true)
    throw problem("관리자 권한이 필요합니다.", 403);
  return {
    id: data.user.id,
    name: String(
      data.user.user_metadata?.name ||
        data.user.user_metadata?.full_name ||
        "관리자",
    ).slice(0, 120),
  };
}
export function externalStore(env = process.env) {
  const url = env.SUPABASE_ADMIN_URL || env.VITE_SUPABASE_ADMIN_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SERVICE_KEY;
  if (!url || !key)
    throw problem("관리자 변경 이력 연결을 확인해 주세요.", 503);
  const db = createClient(url, key, options());
  const unwrap = ({ data, error }) => {
    if (error)
      throw problem(
        "초안·변경 이력을 저장하지 못했습니다. 다시 조회해 주세요.",
        503,
      );
    return data;
  };
  return {
    async history(account) {
      return unwrap(
        await db
          .from("admin_external_actions")
          .select(
            "id,actor_id,actor_name,kind,action,object_id,review,state,result,created_at,finished_at,expires_at",
          )
          .eq("account_id", account)
          .order("created_at", { ascending: false })
          .limit(100),
      );
    },
    async rateLimit(actor) {
      unwrap(
        await db
          .from("admin_external_actions")
          .update({ state: "expired", payload: null })
          .eq("state", "prepared")
          .lt("expires_at", new Date().toISOString())
          .select("id"),
      );
      const { count, error } = await db
        .from("admin_external_actions")
        .select("id", { count: "exact", head: true })
        .eq("actor_id", actor)
        .gte("created_at", new Date(Date.now() - 60000).toISOString());
      if (error) throw problem("작업 기록을 확인하지 못했습니다.", 503);
      if (count >= 40)
        throw problem("요청이 많습니다. 1분 후 다시 시도해 주세요.", 429);
    },
    async create(row) {
      return unwrap(
        await db
          .from("admin_external_actions")
          .insert(row)
          .select("id,review,state,expires_at")
          .single(),
      );
    },
    async get(id) {
      return unwrap(
        await db
          .from("admin_external_actions")
          .select("*")
          .eq("id", id)
          .maybeSingle(),
      );
    },
    async claim(id) {
      const result = await db
        .from("admin_external_actions")
        .update({ state: "executing" })
        .eq("id", id)
        .eq("state", "prepared")
        .gt("expires_at", new Date().toISOString())
        .select("id")
        .maybeSingle();
      if (result.error?.code === "23505")
        throw problem(
          "같은 광고를 다른 운영진이 처리 중입니다. 잠시 후 상태를 다시 확인해 주세요.",
          409,
        );
      return unwrap(result);
    },
    async finish(id, state, result) {
      return unwrap(
        await db
          .from("admin_external_actions")
          .update({
            state,
            result,
            payload: null,
            finished_at: new Date().toISOString(),
          })
          .eq("id", id)
          .select("id")
          .single(),
      );
    },
    async drafts() {
      return unwrap(
        await db
          .from("admin_external_drafts")
          .select(
            "id,kind,title,payload,version,updated_at,created_by,updated_by",
          )
          .is("archived_at", null)
          .order("updated_at", { ascending: false })
          .limit(100),
      );
    },
    async saveDraft(input, actor) {
      const row = {
        kind: input.kind,
        title: input.title,
        payload: input.payload,
        updated_by: actor,
        updated_at: new Date().toISOString(),
      };
      if (!input.id)
        return unwrap(
          await db
            .from("admin_external_drafts")
            .insert({ ...row, provider: "meta", created_by: actor })
            .select("id,version")
            .single(),
        );
      const saved = unwrap(
        await db
          .from("admin_external_drafts")
          .update({ ...row, version: input.version + 1 })
          .eq("id", input.id)
          .eq("version", input.version)
          .is("archived_at", null)
          .select("id,version")
          .maybeSingle(),
      );
      if (!saved)
        throw problem(
          "다른 운영진이 초안을 수정했습니다. 목록을 새로고침해 주세요.",
          409,
        );
      return saved;
    },
    async archiveDraft(id, version) {
      const data = unwrap(
        await db
          .from("admin_external_drafts")
          .update({ archived_at: new Date().toISOString() })
          .eq("id", id)
          .eq("version", version)
          .is("archived_at", null)
          .select("id")
          .maybeSingle(),
      );
      if (!data) throw problem("초안이 변경됐습니다. 다시 조회해 주세요.", 409);
      return data;
    },
  };
}
