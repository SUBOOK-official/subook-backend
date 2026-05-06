// 식스샵 상품 xlsx → Supabase products 매핑 JSON 변환.
// 1회성 마이그레이션 스크립트. 사용법:
//   1) xlsx의 xl/worksheets/sheet1.xml을 미리 푼 후 그 경로를 인자로 전달
//   2) node parse-products.mjs <sheet1.xml-path> [output-dir]
//
// 출력:
//   output/products-mapped.json         — 우리 schema로 매핑된 상품 (n개)
//   output/products-failures.json       — 매핑 실패 또는 의심 케이스
//   output/categories-uniq.json         — 발견된 unique 카테고리/브랜드/타입 (검증용)

import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const sheetPath = process.argv[2];
const outDir = resolve(process.argv[3] ?? `${__dirname}/output`);

if (!sheetPath) {
  console.error("Usage: node parse-products.mjs <sheet1.xml-path> [output-dir]");
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });

const xml = readFileSync(sheetPath, "utf-8");

// xlsx sheet1.xml 파싱 — 정규식. 셀은 <c r="A2" t="str"><v>...</v></c> 형태
// 빈 셀은 보통 <c r="X" t="str"><v></v></c> 또는 아예 없음.
function parseSheet(text) {
  const rows = [];
  // <row r="N" ...> ... </row>
  const rowRe = /<row r="(\d+)"[^>]*>([\s\S]*?)<\/row>/g;
  // <c r="A1" t="str"><v>...</v></c>  /  <c r="A1"><v>123</v></c> (number)
  const cellRe = /<c r="([A-Z]+)\d+"[^>]*?>(?:<v>([^<]*)<\/v>)?<\/c>/g;
  let m;
  while ((m = rowRe.exec(text)) !== null) {
    const rowNum = parseInt(m[1], 10);
    const inner = m[2];
    const cells = {};
    let cm;
    while ((cm = cellRe.exec(inner)) !== null) {
      cells[cm[1]] = decodeXml(cm[2] ?? "");
    }
    rows.push({ rowNum, cells });
  }
  return rows;
}

function decodeXml(s) {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, "\"")
    .replace(/&apos;/g, "'");
}

// 카테고리 문자열 (예: "브랜드 > 시대인재||유형별 교재 > 모의고사||영역별 교재 > 과학탐구")
//  → { '브랜드': ['시대인재'], '유형별 교재': ['모의고사'], '영역별 교재': ['과학탐구'] }
// 같은 키가 여러 번이면 배열로. 호출 측에서 첫 번째만 취함.
function parseCategories(s) {
  if (!s) return {};
  const out = {};
  for (const part of s.split("||")) {
    const t = part.trim();
    const arrowIdx = t.indexOf(">");
    if (arrowIdx === -1) continue;
    const k = t.slice(0, arrowIdx).trim();
    const v = t.slice(arrowIdx + 1).trim();
    if (!out[k]) out[k] = [];
    out[k].push(v);
  }
  return out;
}

// 카테고리 키별 값 배열 → 우리 enum에 매칭되는 첫 번째 선택 (없으면 첫 번째 그대로)
function pickEnumValue(values, knownSet) {
  if (!Array.isArray(values) || values.length === 0) return null;
  const matched = values.find((v) => knownSet.has(v));
  return matched ?? values[0];
}

const SUBJECT_NORMALIZE = {
  과학탐구: "과학",
  사회탐구: "사회",
  전체: "기타", // 식스샵의 "전체" 과목 (전 과목용 책)은 "기타"로 매핑
  // 그 외 그대로
};

const KNOWN_BRANDS = new Set([
  "시대인재", "강남대성", "대성마이맥", "이투스", "EBS",
  "메가스터디", "이감", "상상국어평가연구소",
  "기타",
]);

const KNOWN_BOOK_TYPES = new Set([
  "기출", "모의고사", "N제", "EBS", "주간지", "내신",
  "개념", "워크북",
  "논술",
]);

const KNOWN_SUBJECTS = new Set(["국어", "수학", "영어", "과학", "사회", "한국사", "기타"]);

const STATUS_MAP = {
  "판매중": "selling",
  "품절": "sold_out",
  "판매중지": "hidden",
};

function parseInt0(s) {
  if (!s) return null;
  const cleaned = String(s).replace(/[^0-9-]/g, "");
  if (!cleaned) return null;
  const n = parseInt(cleaned, 10);
  return Number.isFinite(n) ? n : null;
}

// "S(새책)" → "S",  "A+(사용감 적음)" → "A_PLUS"
function parseConditionGrade(s) {
  if (!s) return null;
  const t = s.trim().toUpperCase();
  if (t.startsWith("S")) return "S";
  if (t.startsWith("A+") || t.includes("A_PLUS")) return "A_PLUS";
  if (t.startsWith("A")) return "A";
  return null;
}

// "이해원T" 같은 강사명 뒤에 T가 붙은 패턴을 제목 끝에서 추출
function extractInstructor(title) {
  if (!title) return null;
  const m = title.match(/(\S+)T(?:\s|$)/);
  if (!m) return null;
  // 강사명에 한글/영문이 섞일 수 있어 보수적으로
  return m[1];
}

function extractYear(title) {
  if (!title) return null;
  const m = title.match(/^(\d{4})\b/);
  if (!m) return null;
  const y = parseInt(m[1], 10);
  if (y < 2000 || y > 2100) return null;
  return y;
}

// 제목에서 브랜드 fallback (카테고리 데이터가 비어있을 때)
function inferBrandFromTitle(title) {
  if (!title) return null;
  const order = [
    "상상국어평가연구소",
    "시대인재",
    "강남대성",
    "대성마이맥",
    "메가스터디",
    "이투스",
    "이감",
    "EBS",
  ];
  for (const b of order) {
    if (title.includes(b)) return b;
  }
  return null;
}

// 제목에서 과목 fallback
function inferSubjectFromTitle(title) {
  if (!title) return null;
  // 과학(과학탐구) — 단어 우선순위 높음
  if (/물리|화학|생명과학|생명|지구과학|지구|과학탐구|과탐/.test(title)) return "과학";
  // 사회탐구
  if (/사회문화|생활과 윤리|윤리와 사상|한국지리|세계지리|동아시아사|세계사|정치와 법|경제|사탐|사회탐구/.test(title)) return "사회";
  // 한국사
  if (/한국사/.test(title)) return "한국사";
  // 수학 (확률과 통계, 미적분, 기하 포함)
  if (/수학|확률과 통계|확률과통계|미적분|기하|수1|수2|수I|수II/.test(title)) return "수학";
  // 영어
  if (/영어|워드마스터|WORD MASTER|영단어|영문법/i.test(title)) return "영어";
  // 국어
  if (/국어|문학|독서|화법과 작문|언어와 매체|언매|화작|독해|국문/.test(title)) return "국어";
  return null;
}

// 제목에서 책 타입 fallback
function inferBookTypeFromTitle(title) {
  if (!title) return null;
  if (/모의고사|실모|실전\s*모의|봉투|파이널|FINAL|브릿지/i.test(title)) return "모의고사";
  if (/기출|평가원|수능기출/.test(title)) return "기출";
  if (/N제|n제/.test(title)) return "N제";
  if (/EBS|수능특강|수능완성/i.test(title)) return "EBS";
  if (/주간지|일주|주차/.test(title)) return "주간지";
  if (/내신/.test(title)) return "내신";
  if (/워크북/.test(title)) return "워크북";
  if (/논술/.test(title)) return "논술";
  if (/개념|시작|입문|베이직|basic|한권/i.test(title)) return "개념";
  return null;
}

const rows = parseSheet(xml);
console.log(`Parsed ${rows.length} rows from sheet`);

// 헤더 row 제거
const dataRows = rows.filter((r) => r.rowNum > 1);
console.log(`${dataRows.length} data rows`);

const mapped = [];
const failures = [];
const categoryCounts = {};
const brandCounts = {};
const bookTypeCounts = {};
const subjectCounts = {};
const statusCounts = {};

for (const row of dataRows) {
  const c = row.cells;

  const title = c.B?.trim() ?? "";
  const sixshopId = c.C?.trim() ?? null;
  const conditionRaw = c.E ?? "";
  const coverImageUrl = c.F?.trim() || null;
  const retailPrice = parseInt0(c.G);
  const price = parseInt0(c.J);
  const categoriesRaw = c.AD ?? "";
  const optionRaw = c.AG?.trim() ?? "";
  const statusRaw = c.A?.trim() ?? "";

  const cats = parseCategories(categoriesRaw);
  for (const k of Object.keys(cats)) {
    categoryCounts[k] = (categoryCounts[k] ?? 0) + 1;
  }

  // 다중 카테고리는 우리 enum과 매칭되는 첫 번째 우선
  let brand = pickEnumValue(cats["브랜드"], KNOWN_BRANDS);
  let bookType = pickEnumValue(cats["유형별 교재"], KNOWN_BOOK_TYPES);
  let subject = pickEnumValue(cats["영역별 교재"], KNOWN_SUBJECTS);
  if (subject && SUBJECT_NORMALIZE[subject]) subject = SUBJECT_NORMALIZE[subject];

  // 카테고리에 없으면 제목에서 키워드 fallback
  if (!brand) brand = inferBrandFromTitle(title);
  if (!bookType) bookType = inferBookTypeFromTitle(title);
  if (!subject) subject = inferSubjectFromTitle(title);

  if (brand) brandCounts[brand] = (brandCounts[brand] ?? 0) + 1;
  if (bookType) bookTypeCounts[bookType] = (bookTypeCounts[bookType] ?? 0) + 1;
  if (subject) subjectCounts[subject] = (subjectCounts[subject] ?? 0) + 1;
  if (statusRaw) statusCounts[statusRaw] = (statusCounts[statusRaw] ?? 0) + 1;

  const publishedYear = extractYear(title);
  const instructorName = extractInstructor(title);
  const conditionGrade = parseConditionGrade(conditionRaw);
  const status = STATUS_MAP[statusRaw] ?? "hidden";

  // 검증 — products 테이블 NOT NULL + CHECK 제약 기준
  // (published_year는 nullable이라 검증 안 함)
  const issues = [];
  if (!title) issues.push("제목 비어있음");
  if (!subject) issues.push("과목 미파싱");
  else if (!KNOWN_SUBJECTS.has(subject)) issues.push(`과목 enum 매칭 실패: ${subject}`);
  if (!brand) issues.push("브랜드 미파싱");
  else if (!KNOWN_BRANDS.has(brand)) issues.push(`브랜드 enum 매칭 실패: ${brand}`);
  if (!bookType) issues.push("타입 미파싱");
  else if (!KNOWN_BOOK_TYPES.has(bookType)) issues.push(`타입 enum 매칭 실패: ${bookType}`);

  const record = {
    sixshop_id: sixshopId,
    title,
    option: optionRaw || null,
    subject,
    brand,
    book_type: bookType,
    published_year: publishedYear,
    instructor_name: instructorName,
    cover_image_url: coverImageUrl,
    status,
    price,
    retail_price: retailPrice,
    condition_grade: conditionGrade,
    raw: {
      categories: categoriesRaw,
      condition: conditionRaw,
      status: statusRaw,
    },
  };

  if (issues.length > 0) {
    failures.push({ ...record, issues });
  } else {
    mapped.push(record);
  }
}

writeFileSync(`${outDir}/products-mapped.json`, JSON.stringify(mapped, null, 2));
writeFileSync(`${outDir}/products-failures.json`, JSON.stringify(failures, null, 2));
writeFileSync(`${outDir}/categories-uniq.json`, JSON.stringify({
  category_keys: categoryCounts,
  brands: brandCounts,
  book_types: bookTypeCounts,
  subjects: subjectCounts,
  statuses: statusCounts,
}, null, 2));

// 콘솔 통계
console.log("\n=== Summary ===");
console.log(`Total rows:    ${dataRows.length}`);
console.log(`Mapped OK:     ${mapped.length}`);
console.log(`Failed/issues: ${failures.length}`);

console.log("\n=== Brands seen ===");
for (const [k, v] of Object.entries(brandCounts).sort((a, b) => b[1] - a[1])) {
  const ok = KNOWN_BRANDS.has(k) ? "✓" : "✗";
  console.log(`  ${ok} ${k}: ${v}`);
}

console.log("\n=== Book types seen ===");
for (const [k, v] of Object.entries(bookTypeCounts).sort((a, b) => b[1] - a[1])) {
  const ok = KNOWN_BOOK_TYPES.has(k) ? "✓" : "✗";
  console.log(`  ${ok} ${k}: ${v}`);
}

console.log("\n=== Subjects seen (after normalization) ===");
for (const [k, v] of Object.entries(subjectCounts).sort((a, b) => b[1] - a[1])) {
  const ok = KNOWN_SUBJECTS.has(k) ? "✓" : "✗";
  console.log(`  ${ok} ${k}: ${v}`);
}

console.log("\n=== Statuses seen ===");
for (const [k, v] of Object.entries(statusCounts).sort((a, b) => b[1] - a[1])) {
  console.log(`  ${k}: ${v}`);
}

console.log(`\nOutputs written to: ${outDir}`);
