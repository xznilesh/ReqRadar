import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

function walk(dir){
  return fs.existsSync(dir)?fs.readdirSync(dir,{withFileTypes:true}).flatMap((e)=>{
    const p=path.join(dir,e.name);return e.isDirectory()?walk(p):[p];
  }):[];
}
const files=[...walk('lib'),...walk('app'),...walk('supabase/migrations')].filter((p)=>/\.(js|mjs|sql)$/.test(p));
const joined=files.map((f)=>fs.readFileSync(f,'utf8')).join('\n');

for(const table of ['requirement_ai_runs','candidate_intelligence_jobs']){
  if(joined.includes('public.'+table)){
    const matches=files.filter((f)=>fs.readFileSync(f,'utf8').includes('public.'+table));
    assert.ok(matches.length>0);
    const definitions=matches.map((f)=>fs.readFileSync(f,'utf8')).join('\n');
    assert.ok(/agency_id/i.test(definitions),`${table}: AI/job storage must carry tenant context`);
  }
}

for(const file of files.filter((f)=>f.startsWith('app/')||f.startsWith('lib/'))){
  const c=fs.readFileSync(file,'utf8');
  if(/^['"]use client['"];?/m.test(c)){
    assert.ok(!/OPENAI_API_KEY|SUPABASE_SERVICE_ROLE_KEY|DATABASE_URL/.test(c),`${file}: privileged secret referenced in client code`);
  }
}

const vectorFiles=files.filter((f)=>/vector|embedding/i.test(fs.readFileSync(f,'utf8')));
for(const file of vectorFiles){
  const c=fs.readFileSync(file,'utf8');
  if(/<->|<#>|cosine|embedding/i.test(c)&&/candidate/i.test(c)){
    assert.ok(/agency_id|tenant|workspace/i.test(c),`${file}: candidate semantic/vector path lacks an obvious pre-ranking tenant boundary`);
  }
}

const step7=fs.readFileSync('supabase/migrations/20260926153512_20260928_step7_enterprise_multitenant_security_foundation.sql','utf8');
assert.ok(step7.includes('security_rate_limits'),'durable job/cost protection foundation missing');
assert.ok(step7.includes('private.xzrecruiter_session_context'),'job-triggering business RPCs must derive tenant/session context');

console.log(`STEP7_AI_JOB_SECURITY_PASS files=${files.length} client_secrets=false vector_paths=${vectorFiles.length} tenant_boundary=true`);
