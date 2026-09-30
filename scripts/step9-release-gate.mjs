import fs from 'node:fs';
import {spawnSync} from 'node:child_process';

const blockers=[];
function run(command,args,label){
 const r=spawnSync(command,args,{stdio:'inherit',env:process.env});
 if(r.status!==0)blockers.push(label);
}
function validateEvidence(name){
 const raw=String(process.env[name]||'').trim();
 if(!raw){blockers.push('missing_evidence:'+name);return}
 let evidence;
 try{evidence=JSON.parse(raw)}catch{blockers.push('invalid_evidence_json:'+name);return}
 if(evidence?.status!=='PASS'){blockers.push('evidence_not_pass:'+name);return}
 if(!String(evidence?.artifact||'').trim()||!String(evidence?.sha256||'').match(/^[a-f0-9]{64}$/i)){
   blockers.push('evidence_artifact_unbound:'+name);return;
 }
 const observed=Date.parse(evidence?.observedAt||'');
 if(!Number.isFinite(observed)){blockers.push('evidence_time_invalid:'+name);return}
 const maxAgeMs=7*24*60*60*1000;
 if(observed>Date.now()+5*60*1000||Date.now()-observed>maxAgeMs){blockers.push('evidence_stale:'+name);return}
 if(!String(evidence?.scope||'').trim()){blockers.push('evidence_scope_missing:'+name)}
}

run('node',['scripts/step9-repository-audit.mjs'],'repository_audit_failed');

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql'));
const versions=migrations.map(x=>x.split('_')[0]);
if(new Set(versions).size!==versions.length)blockers.push('duplicate_migration_versions');

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
])validateEvidence(evidence);

if(blockers.length){
 console.error('STEP9_RELEASE_BLOCKED '+JSON.stringify([...new Set(blockers)]));
 process.exit(2);
}
console.log('STEP9_RELEASE_GATE_PASS source=true live_db=true security=true ai=true health=true backup_restore=true browser_e2e=true pilot=true');
