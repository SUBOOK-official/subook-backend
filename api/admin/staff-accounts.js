import { createClient } from "@supabase/supabase-js";
import {
  isValidStaffId,
  normalizeStaffId,
  staffEmailFromId,
  staffIdFromEmail,
  staffPasswordProblem,
  STAFF_ID_HINT,
} from "../_lib/staffAccount.js";

/**
 * 직원 계정(교재 등록 담당) 관리 API — 대표 관리자(admin_users.role = 'super') 전용
 *
 *   GET                                               직원 계정 목록 + 계정별 등록 권수
 *   POST {action:"create", loginId, password, displayName}   계정 만들기
 *   POST {action:"set_password", userId, password}           비밀번호 바꾸기
 *   POST {action:"delete", userId}                           계정 삭제(권한 회수 + 로그인 계정 삭제)
 *
 * 만드는 계정은 role='intake' 하나뿐이다 — 이 API로 전체 관리자를 만들거나 관리자 비밀번호를 바꿀 수 없다.
 * 비밀번호는 Supabase Auth에 넘기기만 하고 응답·로그에 남기지 않는다.
 *
 * Supabase Auth 관리 API (service_role 전용, 서버에서만 호출):
 *   https://supabase.com/docs/reference/javascript/auth-admin-createuser
 *   https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid
 *   https://supabase.com/docs/reference/javascript/auth-admin-deleteuser
 */

const DISPLAY_NAME_MAX = 30;
// 삭제가 실패했을 때 대신 거는 로그인 정지 기간(사실상 영구)
const FALLBACK_BAN_DURATION = "876000h";

function fail(res, status, error, code) {
  return res.status(status).json({ error: String(error), code: String(code) });
}

function parseBearerToken(authHeader) {
  const match = String(authHeader || "").match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || "";
}

function getSupabaseUrl() {
  return (
    process.env.SUPABASE_URL ||
    process.env.SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_ADMIN_URL ||
    process.env.VITE_SUPABASE_URL
  );
}

function createServiceClient() {
  // service_role은 VITE_* 키 폴백 금지(클라이언트 번들 위험) — URL만 폴백
  const url = getSupabaseUrl();
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_KEY;
  if (!url || !serviceKey) return null;
  return createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
}

// 로그인 토큰의 주인이 대표 관리자(super)인지 확인한다.
async function assertOwner(accessToken, service) {
  const { data: userResult, error: userError } = await service.auth.getUser(accessToken);
  const user = userResult?.user;
  if (userError || !user) {
    const error = new Error("UNAUTHORIZED");
    error.statusCode = 401;
    throw error;
  }
  const { data: row, error: rowError } = await service
    .from("admin_users")
    .select("role")
    .eq("user_id", user.id)
    .maybeSingle();
  if (rowError) throw new Error(`admin_users: ${rowError.message}`);
  if (row?.role !== "super") {
    const error = new Error("FORBIDDEN");
    error.statusCode = 403;
    throw error;
  }
  return user;
}

async function findStaffRow(service, userId) {
  const { data, error } = await service
    .from("admin_users")
    .select("email,user_id,role,display_name,created_at")
    .eq("user_id", userId)
    .eq("role", "intake")
    .maybeSingle();
  if (error) throw new Error(`admin_users: ${error.message}`);
  return data;
}

function toAccount(row, { lastSignInAt = null, stats = null } = {}) {
  return {
    userId: row.user_id,
    loginId: staffIdFromEmail(row.email),
    displayName: row.display_name || "",
    createdAt: row.created_at,
    lastSignInAt,
    registered: {
      total: Number(stats?.total || 0),
      today: Number(stats?.today || 0),
      lastAt: stats?.last_at || null,
    },
  };
}

async function listAccounts(service) {
  const { data: rows, error } = await service
    .from("admin_users")
    .select("email,user_id,display_name,created_at")
    .eq("role", "intake")
    .order("created_at", { ascending: false });
  if (error) throw new Error(`admin_users: ${error.message}`);

  const { data: stats, error: statsError } = await service.rpc("admin_staff_registration_stats");
  if (statsError) throw new Error(`admin_staff_registration_stats: ${statsError.message}`);

  return Promise.all(
    (rows || []).map(async (row) => {
      const { data } = await service.auth.admin.getUserById(row.user_id);
      return toAccount(row, {
        lastSignInAt: data?.user?.last_sign_in_at || null,
        stats: stats?.[row.user_id] || null,
      });
    }),
  );
}

async function createAccount(service, owner, body) {
  const loginId = normalizeStaffId(body.loginId);
  const displayName = String(body.displayName || "").trim().slice(0, DISPLAY_NAME_MAX);
  const password = String(body.password || "");

  if (!isValidStaffId(loginId)) {
    return { status: 400, error: `아이디는 ${STAFF_ID_HINT}로 정해 주세요.`, code: "INVALID_LOGIN_ID" };
  }
  if (!displayName) {
    return { status: 400, error: "누구의 계정인지 이름을 적어 주세요.", code: "DISPLAY_NAME_REQUIRED" };
  }
  const passwordProblem = staffPasswordProblem(password);
  if (passwordProblem) return { status: 400, error: passwordProblem, code: "WEAK_PASSWORD" };

  const email = staffEmailFromId(loginId);
  const { data: taken, error: takenError } = await service
    .from("admin_users")
    .select("email")
    .eq("email", email)
    .maybeSingle();
  if (takenError) throw new Error(`admin_users: ${takenError.message}`);
  if (taken) return { status: 409, error: "이미 쓰고 있는 아이디예요. 다른 아이디로 정해 주세요.", code: "LOGIN_ID_TAKEN" };

  // email_confirm: true — 확인 메일 없이 바로 로그인할 수 있는 계정 (메일은 나가지 않는다)
  const { data: created, error: createError } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { name: displayName, staff_role: "intake" },
  });
  if (createError || !created?.user) {
    const message = String(createError?.message || "");
    if (/already|registered|exists/i.test(message)) {
      return { status: 409, error: "이미 쓰고 있는 아이디예요. 다른 아이디로 정해 주세요.", code: "LOGIN_ID_TAKEN" };
    }
    if (createError?.code === "weak_password" || /password/i.test(message)) {
      return { status: 400, error: "비밀번호가 보안 기준에 맞지 않아요. 더 길고 복잡하게 정해 주세요.", code: "WEAK_PASSWORD" };
    }
    throw new Error(`createUser: ${message || "unknown"}`);
  }

  const { data: row, error: insertError } = await service
    .from("admin_users")
    .insert({
      email,
      user_id: created.user.id,
      role: "intake",
      display_name: displayName,
      created_by: owner.id,
    })
    .select("email,user_id,display_name,created_at")
    .single();
  if (insertError) {
    // 권한 행을 못 만들었으면 로그인 계정도 남기지 않는다
    await service.auth.admin.deleteUser(created.user.id).catch(() => {});
    throw new Error(`admin_users insert: ${insertError.message}`);
  }

  return { status: 200, body: { ok: true, account: toAccount(row) } };
}

async function setPassword(service, body) {
  const userId = String(body.userId || "");
  const password = String(body.password || "");
  const passwordProblem = staffPasswordProblem(password);
  if (passwordProblem) return { status: 400, error: passwordProblem, code: "WEAK_PASSWORD" };

  // 직원(intake) 계정만 — 관리자 계정의 비밀번호는 이 API로 바꿀 수 없다
  const row = await findStaffRow(service, userId);
  if (!row) return { status: 404, error: "직원 계정을 찾지 못했어요.", code: "STAFF_NOT_FOUND" };

  const { error } = await service.auth.admin.updateUserById(userId, { password });
  if (error) {
    if (error.code === "weak_password" || /password/i.test(String(error.message))) {
      return { status: 400, error: "비밀번호가 보안 기준에 맞지 않아요. 더 길고 복잡하게 정해 주세요.", code: "WEAK_PASSWORD" };
    }
    throw new Error(`updateUserById: ${error.message}`);
  }
  return { status: 200, body: { ok: true } };
}

async function deleteAccount(service, body) {
  const userId = String(body.userId || "");
  const row = await findStaffRow(service, userId);
  if (!row) return { status: 404, error: "직원 계정을 찾지 못했어요.", code: "STAFF_NOT_FOUND" };

  // 1) 권한 행 삭제 — 이 순간부터 이미 로그인해 있던 화면에서도 모든 요청이 막힌다
  const { error: revokeError } = await service
    .from("admin_users")
    .delete()
    .eq("user_id", userId)
    .eq("role", "intake");
  if (revokeError) throw new Error(`admin_users delete: ${revokeError.message}`);

  // 2) 로그인 계정 삭제. 실패하면 로그인 정지로 대신한다(권한은 이미 없다).
  const { error: deleteError } = await service.auth.admin.deleteUser(userId);
  if (deleteError) {
    console.error("[staff-accounts] deleteUser failed:", deleteError.message);
    const { error: banError } = await service.auth.admin.updateUserById(userId, { ban_duration: FALLBACK_BAN_DURATION });
    if (banError) console.error("[staff-accounts] ban fallback failed:", banError.message);
    return { status: 200, body: { ok: true, loginRemoved: false } };
  }
  return { status: 200, body: { ok: true, loginRemoved: true } };
}

export default async function handler(req, res) {
  if (req.method !== "GET" && req.method !== "POST") {
    res.setHeader("Allow", "GET, POST");
    return fail(res, 405, "Method not allowed.", "METHOD_NOT_ALLOWED");
  }
  res.setHeader("Cache-Control", "no-store");

  const service = createServiceClient();
  if (!service) return fail(res, 500, "Server misconfigured.", "SUPABASE_CONFIG_MISSING");

  const token = parseBearerToken(req.headers.authorization);
  if (!token) return fail(res, 401, "Missing authorization token.", "MISSING_AUTH_TOKEN");

  try {
    const owner = await assertOwner(token, service);

    if (req.method === "GET") {
      return res.status(200).json({ ok: true, accounts: await listAccounts(service) });
    }

    let body = {};
    try {
      body = typeof req.body === "string" ? JSON.parse(req.body || "{}") : req.body || {};
    } catch {
      return fail(res, 400, "Invalid JSON body.", "INVALID_JSON_BODY");
    }

    let result;
    if (body.action === "create") result = await createAccount(service, owner, body);
    else if (body.action === "set_password") result = await setPassword(service, body);
    else if (body.action === "delete") result = await deleteAccount(service, body);
    else return fail(res, 400, "Unknown action.", "UNKNOWN_ACTION");

    if (result.error) return fail(res, result.status, result.error, result.code);
    return res.status(result.status).json(result.body);
  } catch (error) {
    if (error?.statusCode === 401) return fail(res, 401, "로그인이 필요해요.", "UNAUTHORIZED");
    if (error?.statusCode === 403) return fail(res, 403, "대표 관리자 계정만 직원 계정을 관리할 수 있어요.", "FORBIDDEN");
    console.error("[staff-accounts]", error?.message || error);
    return fail(res, 500, "직원 계정을 처리하지 못했어요. 잠시 후 다시 시도해 주세요.", "STAFF_ACCOUNTS_FAILED");
  }
}
