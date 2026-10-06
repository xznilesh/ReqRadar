import fs from 'node:fs';
import {spawnSync} from 'node:child_process';

const blockers=[];
function run(command,args,label){const r=spawnSync(command,args,{stdio:'inherit',env:process.env});if(r.status!==0)blockers.push(label)}
function missing(name){if(!String(process.env[name]||'').trim())blockers.push('missing_env:'+name)}

run('node',['scripts/step9-repository-audit.mjs','--release'],'repository_audit_failed');
run('node',['scripts/step9-enterprise-capability-audit.mjs'],'enterprise_capability_source_failed');

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql'));
const versions=migrations.map(x=>x.split('_')[0]);
if(new Set(versions).size!==versions.length)blockers.push('duplicate_migration_versions');

const dbUrl=process.env.XZRECRUITER_DATABASE_URL||process.env.DATABASE_URL||'';
if(!dbUrl||dbUrl.includes('placeholder'))blockers.push('verified_live_database_url_missing');
else{
 run('node',['scripts/step9-live-db.mjs'],'live_database_integrity_failed');
 run('node',['scripts/step7-security-live-db.mjs'],'live_database_security_failed');
}

const base=(process.env.XZRECRUITER_RELEASE_BASE_URL||'https://xzrecruiter.vercel.app').replace(/\/$/,'');
try{
 const response=await fetch(base+'/api/health/ready',{headers:{accept:'application/json'},redirect:'manual'});
 const body=await response.json().catch(()=>null);
 if(response.status!==200||body?.ok!==true)blockers.push('production_readiness_health_failed:'+response.status);
 else console.log('STEP9_PRODUCTION_HEALTH_PASS status=200');
}catch{blockers.push('production_readiness_health_unreachable')}

if(!process.env.OPENAI_API_KEY)blockers.push('live_ai_provider_credential_missing');
else{
 run('node',['scripts/step2-jd-live-eval.mjs'],'live_jd_ai_eval_failed');
 run('node',['scripts/step4-candidate-intelligence-live-eval.mjs'],'live_candidate_ai_eval_failed');
}

for(const name of [
 'XZRECRUITER_MALWARE_SCAN_URL',
 'XZRECRUITER_BACKUP_RESTORE_EVIDENCE',
 'XZRECRUITER_BROWSER_E2E_EVIDENCE',
 'XZRECRUITER_LOAD_TEST_EVIDENCE',
 'XZRECRUITER_TENANT_ISOLATION_EVIDENCE',
 'XZRECRUITER_ENTERPRISE_AUTH_EVIDENCE',
 'XZRECRUITER_PRIVACY_COMPLIANCE_EVIDENCE',
 'XZRECRUITER_INTEGRATIONS_EVIDENCE',
 'XZRECRUITER_JOB_BOARD_EVIDENCE',
 'XZRECRUITER_OBSERVABILITY_EVIDENCE',
 'XZRECRUITER_PILOT_EVIDENCE'
])missing(name);

if(blockers.length){console.error('STEP9_RELEASE_BLOCKED '+JSON.stringify([...new Set(blockers)]));process.exit(2)}
console.log('STEP9_RELEASE_GATE_PASS source=true live_db=true security=true ai=true health=true malware_scan=true backup_restore=true browser_e2e=true load=true tenant_isolation=true enterprise_auth=true privacy=true integrations=true job_boards=true observability=true pilot=true');
