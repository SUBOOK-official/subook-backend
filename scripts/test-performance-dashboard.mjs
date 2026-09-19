// 운영 데이터 접속 없이 실제 RPC와 수수료 함수를 격리 PostgreSQL에서 검증한다.
// 실행: node backend/scripts/test-performance-dashboard.mjs
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const read = (name) => readFileSync(new URL('../supabase/' + name, import.meta.url), 'utf8');
const legacy = read('migrations/2026041203_settlement_automation.sql')
  .match(/create or replace function public\.calculate_settlement_fee_percent\([\s\S]*?\$\$;/)[0];
const policy = read('migrations/20260910054749_pickup_fee_policy_versions.sql')
  .match(/create function public\.calculate_settlement_fee_percent\([\s\S]*?\$\$;/)[0];
const migration = read('migrations/20260919143454_admin_performance_repeat_commission.sql')
  .replace(/^begin;$/m, '').replace(/^commit;$/m, '');
const body = [legacy, policy, migration].join('\n')
  .replaceAll('public.', 'performance_test.').replaceAll('search_path = public', 'search_path = performance_test');
const sql = read('tests/performance_dashboard.sql').replace('-- @@PERFORMANCE_MIGRATION@@', () => body);
const db = new PGlite();
try {
  await db.exec('create role anon; create role authenticated;');
  await db.exec(sql);
  console.log('PASS: 기존 성과 집계·관리자 권한·전체 이력 재구매·6종 혼합 수수료·환불/미확인 제외·일별 대사');
} finally {
  await db.close();
}
