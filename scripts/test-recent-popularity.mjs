// 읽기 전용: migration의 실제 SELECT 본문을 가상 데이터로 검증한다.
// 실행: node backend/scripts/test-recent-popularity.mjs (프로젝트 루트)
// DB 객체·운영 데이터를 생성하거나 수정하지 않는다.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const env = {};
for (const path of [".env", ".env.local"]) {
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (match) env[match[1]] = match[2].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
}
assert.equal(new URL(env.VITE_SUPABASE_URL).hostname.split(".")[0], env.SUPABASE_PROJECT_REF);
const migration = readFileSync(new URL("../supabase/migrations/20260908041225_recent_order_popularity.sql", import.meta.url), "utf8");
const body = migration.match(/as \$\$([\s\S]*?)\$\$;/)[1].trim().replace(/;$/, "");
const defaults = {
  p_subjects: "null::text[]", p_book_types: "null::text[]", p_brands: "null::text[]",
  p_years: "null::integer[]", p_condition_grades: "null::text[]", p_search: "null::text",
  p_sort: "'popular'::text", p_limit: "500", p_offset: "0",
  p_instructors: "null::text[]", p_title_terms: "null::text[]",
};

const fixtures = `
fixture_products as (
 select id::bigint, 'fixture ' || id as title, null::text as option,
 case when id in (1,5) then '국어' else '수학' end::text as subject,
 '시대인재'::text as brand, '모의고사'::text as book_type,
 case when id in (1,5) then 2027 else 2026 end::integer as published_year,
 '강사'::text as instructor_name, null::text as cover_image_url,
 ('fixture ' || id || ' 시대인재')::text as search_text, 'ㅅㄷㅇㅈ'::text as search_chosung,
 case when id=4 then 1000000 else 0 end::integer as legacy_sales_count
 from generate_series(1,12) id
),
fixture_books as (
 select id * 10 as id, id as product_id, 'S'::text as condition_grade,
 (1000 + id * 100)::integer as price, 10000::integer as original_price,
 null::text as cover_image_url, array[]::text[] as inspection_image_urls,
 0::integer as writing_percentage, false as has_damage, null::text as inspection_notes,
 now() as inspected_at,
 now() - case when id=5 then interval '1 hour' when id=6 then interval '1 day' else interval '20 days' end as created_at,
 case when id=7 then 'sold_out' else 'on_sale' end::text as status,
 id <> 8 as is_public, null::text as option, published_year
 from fixture_products
),
fixture_orders(id,status,payment_status,paid_at,pg_approved_at) as (
 values
 (1::bigint,'confirmed','paid',now()-interval '1 day',null::timestamptz),
 (2,'confirmed','paid',now()-interval '2 days',null),
 (3,'confirmed','paid',now()-interval '3 days',null),
 (4,'confirmed','paid',now()-interval '30 days',null),
 (5,'confirmed','paid',now()-interval '7 days',null),
 (6,'confirmed','paid',now()-interval '8 days',null),
 (7,'pending','pending',now(),null),
 (8,'cancelled','paid',now(),null),
 (9,'refunded','paid',now(),null),
 (10,'pending','failed',now(),null),
 (11,'confirmed','paid',now()-interval '31 days',null),
 (12,'confirmed','paid',now()+interval '1 day',null),
 (13,'confirmed','paid',null,now()-interval '1 day'),
 (14,'confirmed','paid',null,null)
),
fixture_order_items(product_id,order_id,quantity,refunded_at) as (
 values
 (1::bigint,1::bigint,1,null::timestamptz),(1,1,1,null),(1,2,1,null),(1,3,1,null),
 (2,1,20,null),(3,1,20,null),
 (6,7,100,null),(6,8,100,null),(6,9,100,null),(6,10,100,null),
 (6,1,100,now()),(6,11,100,null),(6,12,100,null),(6,14,100,null),
 (7,1,1,null),(8,1,1,null),
 (9,1,1,null),(10,6,10,null),
 (11,13,1,null),(11,13,50,now()),
 (12,4,1,null),(12,5,1,null)
),
fixture_wishlist_items as (
 select 3::bigint as product_id union all select 3
 union all select 11 union all select 4 from generate_series(1,100)
 union all select 6 from generate_series(1,100)
)
`;
function query(overrides = {}, fixture = true) {
  let sql = body;
  for (const [name, value] of Object.entries({ ...defaults, ...overrides })) {
    sql = sql.replace(new RegExp("\\b" + name + "\\b", "g"), value);
  }
  if (fixture) {
    sql = sql.replace(/^with /, "with " + fixtures + ", ");
    for (const name of ["products", "books", "orders", "order_items", "wishlist_items"]) {
      sql = sql.replaceAll("public." + name, "fixture_" + name);
    }
  }
  return sql;
}
async function run(sql) {
  for (let attempt=0; attempt<2; attempt++) {
    const response = await fetch("https://api.supabase.com/v1/projects/" + env.SUPABASE_PROJECT_REF + "/database/query", {
      method: "POST",
      headers: { Authorization: "Bearer " + env.SUPABASE_ACCESS_TOKEN, "Content-Type": "application/json" },
      body: JSON.stringify({ query: sql, read_only: true }),
      signal: AbortSignal.timeout(30000),
    });
    if (response.ok) return response.json();
    if (response.status >= 500 && attempt === 0) continue;
    throw new Error("Read-only SQL verification HTTP " + response.status + ": " + await response.text());
  }
}
const variants = {
  baseline: {},
  page: { p_limit:"3", p_offset:"3" },
  year: { p_search:"'2027'::text" },
  subject: { p_subjects:"array['국어']::text[]" },
  instructor: { p_instructors:"array['없는강사']::text[]" },
  series: { p_title_terms:"array['fixture 12']::text[]" },
  grade: { p_condition_grades:"array['A']::text[]" },
  price: { p_sort:"'price_low'::text" },
  latest: { p_sort:"'latest'::text" },
};
const pairs = Object.entries(variants).map(([name,args]) =>
  "'" + name + "',coalesce((select jsonb_agg(t) from (" + query(args) + ")t),'[]'::jsonb)"
);
const [result] = await run("select jsonb_build_object(" + pairs.join(",") + ") as tests");
const ids = (name) => result.tests[name].map(row => row.id);
assert.deepEqual(ids("baseline"), [1,12,3,2,11,9,10,5,6,4]);
assert.deepEqual(ids("page"), [2,11,9]);
assert.equal(result.tests.page[0].total_count, 10);
assert.deepEqual(ids("year"), [1,5]);
assert.deepEqual(ids("subject"), [1,5]);
assert.deepEqual(ids("instructor"), []);
assert.deepEqual(ids("series"), [12]);
assert.deepEqual(ids("grade"), []);
assert.deepEqual(ids("price"), [1,2,3,4,5,6,9,10,11,12]);
assert.deepEqual(ids("latest").slice(0,2), [5,6]);
const scores=result.tests.baseline.map(row=>row.popularity_score);
assert.ok(scores.every((value,index)=>index===0 || value<scores[index-1]));
assert.equal(result.tests.page[0].popularity_score,result.tests.baseline[3].popularity_score);
console.log("PASS: 주문 중복, 30일/7일 경계, 수량, 찜, PG 시각 fallback, 미결제/취소/전체·부분환불/과거·미래 제외, 신규 입고, 품절·비공개, 검색·필터, 페이지네이션, 가격·최신 정렬 (12 assertions)");
const preview = await run("select id,title,popularity_score,total_count from (" + query({p_limit:"12"},false) + ")t");
console.log(JSON.stringify({ proposedTop12: preview },null,2));

