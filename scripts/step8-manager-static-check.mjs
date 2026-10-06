import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const jsFiles=[
  'lib/manager-control.mjs','lib/manager-control-server.js','lib/server-rpc.js',
  'app/api/manager-control/route.js','app/api/automation/run/route.js',
  'app/components/ManagerControlCenter.js','app/components/ManagerRequirementControl.js',
  'app/components/AutomationNotificationCenter.js',
  'scripts/step8-manager-unit-tests.mjs','scripts/step8-manager-integration-tests.mjs',
  'scripts/step8-manager-e2e-tests.mjs','scripts/step8-manager-security-tests.mjs',
  'scripts/step8-manager-concurrency-tests.mjs','scripts/step8-manager-performance-tests.mjs'
];
for(const file of jsFiles){
  const result=spawnSync(process.execPath,['--check',file],{stdio:'inherit'});
  if(result.status!==0)process.exit(result.status||1);
}

const core=fs.readFileSync('supabase/migrations/20260926153517_20260929_step8_automation_manager_core.sql','utf8');
const rpcs=fs.readFileSync('supabase/migrations/20260926153522_20260929_step8_automation_manager_rpcs.sql','utf8');
for(const [tag,count] of [
  ['$$',(rpcs.match(/\$\$/g)||[]).length],
  ['$alert$',(rpcs.match(/\$alert\$/g)||[]).length],
  ['$events$',(rpcs.match(/\$events\$/g)||[]).length],
  ['$step8_events$',(rpcs.match(/\$step8_events\$/g)||[]).length],
  ['$step8_full$',(rpcs.match(/\$step8_full\$/g)||[]).length]
]){
  assert.equal(count%2,0,'unbalanced SQL dollar quote '+tag);
}
assert.ok(core.includes('create extension if not exists pg_cron'));
assert.ok(rpcs.includes('select cron.schedule('));
assert.ok(!/\bdrop\s+table\b|\btruncate\b/i.test(core+rpcs),'Step-8 migration must not destructively drop/truncate business tables');

console.log('STEP8_MANAGER_STATIC_PASS js_syntax=true sql_delimiters=true migration_non_destructive=true');
