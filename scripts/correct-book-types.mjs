// 2026-09-30 전수 점검에서 사용자에게 제시하고 수정 요청받은 43종만 처리한다.
// 기본은 실제 트리거를 실행한 뒤 ROLLBACK. --apply일 때만 COMMIT.
// node backend/scripts/correct-book-types.mjs [--apply|--with-migration]
import {readFileSync,writeFileSync,existsSync,mkdirSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseEnv} from 'node:util';

const here=dirname(fileURLToPath(import.meta.url)), root=resolve(here,'../..');
const mode=process.argv[2] || '--dry-run';
if(!['--dry-run','--apply','--with-migration'].includes(mode))throw new Error('Unknown mode');
for(const name of ['.env','.env.local','backend/.env']) {
 const path=resolve(root,name);
 if(existsSync(path))Object.assign(process.env,parseEnv(readFileSync(path,'utf8')));
}
const ref=process.env.SUPABASE_PROJECT_REF;
if(!ref || new URL(process.env.VITE_SUPABASE_URL).hostname.split('.')[0]!==ref
 || readFileSync(resolve(root,'backend/supabase/.temp/project-ref'),'utf8').trim()!==ref)throw new Error('Project reference mismatch');
const fixes=JSON.parse(readFileSync(resolve(here,'data/book-type-corrections-20260930.json'),'utf8'));
if(fixes.length!==43 || new Set(fixes.map(r=>r.id)).size!==43)throw new Error('Correction scope mismatch');
const records=JSON.stringify(fixes).replaceAll("'","''");
async function query(sql,readOnly=true) {
 const response=await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`,{
  method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_ACCESS_TOKEN}`,'Content-Type':'application/json'},
  body:JSON.stringify({query:sql,read_only:readOnly}),signal:AbortSignal.timeout(60000),
 });
 const data=await response.json();
 if(!response.ok)throw new Error(JSON.stringify(data));
 return data;
}
const dir=resolve(root,'tools/book-type-audit-20260930');
mkdirSync(dir,{recursive:true});
const ids=fixes.map(x=>x.id).join(',');
const backup=await query(`select jsonb_build_object(
 'products',(select jsonb_agg(jsonb_build_object('id',id,'title',title,'book_type',book_type,'group_key',group_key)) from products where id in (${ids})),
 'books',(select jsonb_agg(jsonb_build_object('id',id,'product_id',product_id,'book_type',book_type)) from books where product_id in (${ids}))
) backup;`);
writeFileSync(resolve(dir,`before-corrections-${mode.slice(2)}-${Date.now()}.json`),JSON.stringify(backup,null,2));
const sql=`
begin;
set local lock_timeout='5s';
set local statement_timeout='45s';
${mode==='--with-migration'?readFileSync(resolve(here,'../supabase/migrations/20260930074813_book_type_classification_review.sql'),'utf8'):''}
create temporary table type_corrections on commit drop as
select * from jsonb_to_recordset('${records}'::jsonb) as x(id bigint,title text,previous_type text,book_type text,reason text,source_url text);
do $$ begin
 perform 1 from products p join type_corrections c on c.id=p.id order by p.id for update of p;
 perform 1 from books b join type_corrections c on c.id=b.product_id order by b.id for update of b;
 if (select count(*) from products p join type_corrections c on c.id=p.id and c.title=p.title and c.previous_type=p.book_type)<>43 then
  raise exception '상품명 또는 기존 유형이 변경됐습니다. 감사 스냅샷과 다시 대조해야 합니다.';
 end if;
 if exists(select 1 from books b join type_corrections c on c.id=b.product_id where b.book_type is not null and b.book_type<>c.previous_type) then
  raise exception '재고 유형이 기존 상품 유형과 다릅니다. 재확인이 필요합니다.';
 end if;
 if exists(select 1 from products p join type_corrections c on c.id=p.id join products q on q.id<>p.id
   and q.group_key=storefront_product_group_key(p.title,p.option,p.subject,p.brand,c.book_type,p.published_year,p.instructor_name)) then
  raise exception '교정 후 상품 그룹 키 충돌';
 end if;
end $$;
create temporary table type_products_before on commit drop as select p.* from products p join type_corrections c on c.id=p.id;
create temporary table type_books_before on commit drop as select b.* from books b join type_corrections c on c.id=b.product_id;
update books b set book_type=c.book_type from type_corrections c where b.product_id=c.id;
-- 재고 갱신 트리거가 대표 권의 옵션 등을 되비추므로 원래 상품 메타데이터를 보존한다.
update products p set title=s.title,option=s.option,subject=s.subject,brand=s.brand,
 book_type=c.book_type,published_year=s.published_year,instructor_name=s.instructor_name,cover_image_url=s.cover_image_url,
 group_key=storefront_product_group_key(s.title,s.option,s.subject,s.brand,c.book_type,s.published_year,s.instructor_name),updated_at=now()
from type_products_before s join type_corrections c on c.id=s.id where p.id=s.id;
insert into product_type_reviews(product_id,title,previous_type,book_type,method,evidence)
select id,title,previous_type,book_type,'audit_correction',jsonb_build_object('audit_date','2026-09-30','reason',reason,'source_url',source_url)
from type_corrections;
do $$ begin
 if exists(select 1 from products p join type_corrections c on c.id=p.id where p.book_type<>c.book_type)
 or exists(select 1 from books b join type_corrections c on c.id=b.product_id where b.book_type is distinct from c.book_type) then
  raise exception '유형 교정 결과 불일치';
 end if;
 if exists(select 1 from books b join type_books_before s on s.id=b.id where (to_jsonb(b)-array['book_type','updated_at']) is distinct from (to_jsonb(s)-array['book_type','updated_at'])) then
  raise exception '유형 외 재고 데이터가 바뀌었습니다.';
 end if;
 if exists(select 1 from products p join type_products_before s on s.id=p.id where
   row(p.title,p.option,p.subject,p.brand,p.published_year,p.instructor_name,p.cover_image_url,p.status,p.is_listed)
   is distinct from row(s.title,s.option,s.subject,s.brand,s.published_year,s.instructor_name,s.cover_image_url,s.status,s.is_listed)) then
  raise exception '유형 외 상품 메타데이터 또는 공개 상태가 바뀌었습니다.';
 end if;
end $$;
select (select count(*) from type_corrections)::int corrected_products,(select count(*) from type_books_before)::int corrected_books,
 (select count(*) from product_type_reviews where method='audit_correction' and evidence->>'audit_date'='2026-09-30')::int review_records;
${mode==='--apply'?'commit;':'rollback;'}
`;
const result=await query(sql,false);
writeFileSync(resolve(dir,`correction-result-${mode.slice(2)}.json`),JSON.stringify(result,null,2));
console.log(JSON.stringify({mode,result},null,2));
