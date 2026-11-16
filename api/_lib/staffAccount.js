// 교재 등록 담당(알바) 계정의 아이디·비밀번호 규칙.
// 화면(로그인·직원 계정)과 서버 API(/api/admin/staff-accounts)가 같은 규칙을 쓰도록 한 곳에 둔다.
//
// 직원 계정은 메일함이 없는 전용 주소(<아이디>@staff.subook.kr)로 만든다.
//  - 실제 메일이 나가지 않는다(가입 확인 메일 없이 바로 쓰는 계정).
//  - 고객 이메일과 겹칠 일이 없다.
//  - 로그인 화면에서는 "@" 없이 아이디만 입력하면 된다.

export const STAFF_EMAIL_DOMAIN = "staff.subook.kr";
export const STAFF_ID_HINT = "영문 소문자로 시작, 영문·숫자 4~20자";
export const STAFF_PASSWORD_MIN_LENGTH = 10;

const STAFF_ID_PATTERN = /^[a-z][a-z0-9]{3,19}$/;
// 헷갈리는 글자(0·O, 1·l·I)를 뺀 글자표 — 종이에 적어 건네도 읽기 쉽게
const PASSWORD_LETTERS = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ";
const PASSWORD_DIGITS = "23456789";

export function normalizeStaffId(input) {
  return String(input || "").trim().toLowerCase();
}

export function isValidStaffId(id) {
  return STAFF_ID_PATTERN.test(String(id || ""));
}

export function staffEmailFromId(id) {
  return `${normalizeStaffId(id)}@${STAFF_EMAIL_DOMAIN}`;
}

export function isStaffEmail(email) {
  return String(email || "").trim().toLowerCase().endsWith(`@${STAFF_EMAIL_DOMAIN}`);
}

// 직원 계정이면 아이디만, 아니면 이메일 그대로
export function staffIdFromEmail(email) {
  const value = String(email || "").trim().toLowerCase();
  return isStaffEmail(value) ? value.slice(0, -(STAFF_EMAIL_DOMAIN.length + 1)) : value;
}

// 로그인 입력값 → 실제 로그인 이메일. "@"가 없으면 직원 아이디로 본다.
export function toLoginEmail(input) {
  const value = String(input || "").trim();
  if (!value) return "";
  return value.includes("@") ? value : staffEmailFromId(value);
}

// 문제가 없으면 빈 문자열, 있으면 화면에 보여 줄 안내 문구
export function staffPasswordProblem(password) {
  const value = String(password || "");
  if (value.length < STAFF_PASSWORD_MIN_LENGTH) return `비밀번호는 ${STAFF_PASSWORD_MIN_LENGTH}자 이상이어야 해요.`;
  if (value.length > 72) return "비밀번호는 72자 이하여야 해요.";
  if (!/[A-Za-z]/.test(value) || !/[0-9]/.test(value)) return "비밀번호에 영문과 숫자를 모두 넣어 주세요.";
  if (/\s/.test(value)) return "비밀번호에 공백은 쓸 수 없어요.";
  return "";
}

// 브라우저에서만 쓴다(만든 값은 서버에 저장되기 전까지 화면 밖으로 나가지 않는다).
// randomValues: 길이 n의 Uint32Array를 채워 주는 함수 (기본 crypto.getRandomValues)
export function generateStaffPassword(randomValues = (array) => globalThis.crypto.getRandomValues(array)) {
  const length = 12;
  const pool = PASSWORD_LETTERS + PASSWORD_DIGITS;
  const random = randomValues(new Uint32Array(length + 2));
  const chars = Array.from({ length }, (_, index) => pool[random[index] % pool.length]);
  // 영문·숫자가 반드시 하나씩 들어가게 두 자리는 정해진 글자표에서 뽑는다
  chars[0] = PASSWORD_LETTERS[random[length] % PASSWORD_LETTERS.length];
  chars[length - 1] = PASSWORD_DIGITS[random[length + 1] % PASSWORD_DIGITS.length];
  return chars.join("");
}
