// 하나의 명시한 migration만 dry-run/적용. 다른 세션의 미추적 SQL은 포함하지 않는다.
import { readFileSync, mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const [name, mode = 'dry-run'] = process.argv.slice(2);
if (!/^\d{14}_[a-z0-9_]+\.sql$/.test(name || '') || !['dry-run', 'push', 'list'].includes(mode)) throw Error('Explicit migration name and mode required');
const env = { ...process.env, ...parseEnv(readFileSync('.env','utf8')), ...parseEnv(readFileSync('.env.local','utf8')) };
if (!env.SUPABASE_PROJECT_REF || new URL(env.VITE_SUPABASE_URL).hostname.split('.')[0] !== env.SUPABASE_PROJECT_REF || readFileSync('backend/supabase/.temp/project-ref','utf8').trim() !== env.SUPABASE_PROJECT_REF) throw Error('Project mismatch');
const workdir = '.codex/migration-review/' + name.replace('.sql','');
const hash = createHash('sha256').update(readFileSync('backend/supabase/migrations/'+name)).digest('hex');
mkdirSync(workdir+'/supabase/migrations',{recursive:true}); mkdirSync(workdir+'/supabase/.temp',{recursive:true});
copyFileSync('backend/supabase/config.toml',workdir+'/supabase/config.toml');
for (const file of ['project-ref','pooler-url']) copyFileSync('backend/supabase/.temp/'+file,workdir+'/supabase/.temp/'+file);
const tracked = spawnSync('git',['-C','backend','ls-files','supabase/migrations/*.sql'],{encoding:'utf8',windowsHide:true});
if (tracked.status !== 0) throw Error('git read failed');
for (const path of new Set([...tracked.stdout.trim().split(/\r?\n/),'supabase/migrations/'+name])) copyFileSync('backend/'+path,workdir+'/'+path);
if (mode === 'push' && readFileSync(workdir+'/reviewed-hash.txt','utf8') !== hash) throw Error('Review hash mismatch');
const args = mode === 'list' ? ['migration','list'] : ['db','push',mode === 'push' ? '--yes' : '--dry-run'];
const result = spawnSync('node_modules/supabase/bin/supabase.exe',[...args,'--workdir',workdir,'--password',env.SUPABASE_DB_PASSWORD],{env,encoding:'utf8',windowsHide:true});
const output = (result.stdout || '')+(result.stderr || '');
writeFileSync(workdir+'/'+mode+'.log',output);
if (mode === 'dry-run' && result.status === 0) {
  const pending = [...output.matchAll(/\b(\d{14}_[\w]+\.sql)\b/g)].map(match=>match[1]);
  if (!pending.length || pending.some(file=>file !== name)) throw Error('Unexpected pending migration; inspect dry-run.log');
  writeFileSync(workdir+'/reviewed-hash.txt',hash);
}
console.log(output); process.exitCode = result.status ?? 1;
