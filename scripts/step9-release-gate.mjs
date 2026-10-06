import fs from 'node:fs';
import {spawnSync} from 'node:child_process';

const blockers=[];
function run(command,args,label){
 const r=spawnSync(command,args,{stdio:'inherit',env:process.env});
 if(r.status!==0)blockers.push(label);
}
function missing(name){if(!String(process.env[name]||'').trim())blockers.push('missing_env:'+name)}

run('node',['scripts/step9-repository-audit.mjs'],'repository_audit_failed');

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql')).sort();
const versions=migrations.map(x=>x.split('_')[0]);
if(new Set(versions).size!==versions.length){
 const reconciliationPath='supabase/migration-reconciliation.json';
 try{
  const reconciliation=JSON.parse(fs.readFileSync(reconciliationPath,'utf8'));
  const localNames=migrations.map(x=>x.replace(/\.sql$/,'')).sort();
  const required=[...(reconciliation.required_local_names||[])].sort();
  const valid=reconciliation.schema_version===1
   && reconciliation.strategy==='legacy_duplicate_filename_prefixes_reconciled_by_remote_migration_name'
   && JSON.stringify(required)===JSON.stringify(localNames)
   && Number(reconciliation.local_migration_count)===localNames.length
   && reconciliation.all_local_names_present_remote!==false;
  if(!valid)blockers.push('duplicate_migration_versions_unreconciled');
  else console.log('STEP9_MIGRATION_RECONCILIATION_PASS local='+localNames.length+' remote_snapshot='+Number(reconciliation.remote_migration_count||0));
 }catch{
  blockers.push('duplicate_migration_versions_unreconciled');
 }
}

const dbUrl=process.env.XZRECRUITER_DATABASE_URL||process.env.DATABASE_URL||'';
if(!dbUrl||dbUrl.includes('placeholder'))blockers.push('verified_live_database_url_missing');
else {
 run('node',['scripts/step9-live-db.mjs'],'live_database_integrity_failed');
 run('node',['scripts/step7-security-live-db.mjs'],'live_database_security_failed');
}

const base=(process.env.XZRECRUITER_RELEASE_BASE_URL||'https://xzrecruiter.vercel.app').replace(/\/$/,'');
try{
 const response=await fetch(base+'/api/health/ready',{headers:{accept:'application/json'},redirect:'manual'});
 const body=await response.json().catch(()=>null);
 if(response.status!==200||body?.ok!==true)blockers.push('production_readiness_health_failed:'+response.status);
 else console.log('STEP9_PRODUCTION_HEALTH_PASS status=200');
}catch(error){blockers.push('production_readiness_health_unreachable')}

if(!process.env.OPENAI_API_KEY)blockers.push('live_ai_provider_credential_missing');
else{
 run('node',['scripts/step2-jd-live-eval.mjs'],'live_jd_ai_eval_failed');
 run('node',['scripts/step4-candidate-intelligence-live-eval.mjs'],'live_candidate_ai_eval_failed');
}

for(const evidence of [
 'XZRECRUITER_BACKUP_RESTORE_EVIDENCE',
 'XZRECRUITER_BROWSER_E2E_EVIDENCE',
 'XZRECRUITER_PILOT_EVIDENCE'
])missing(evidence);

if(blockers.length){
 console.error('STEP9_RELEASE_BLOCKED '+JSON.stringify([...new Set(blockers)]));
 process.exit(2);
}
console.log('STEP9_RELEASE_GATE_PASS source=true live_db=true security=true ai=true health=true backup_restore=true browser_e2e=true pilot=true');
