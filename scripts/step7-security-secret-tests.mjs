import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const roots=['app','lib','scripts','supabase'];
function walk(dir){
  return fs.existsSync(dir)?fs.readdirSync(dir,{withFileTypes:true}).flatMap((entry)=>{
    const p=path.join(dir,entry.name);
    return entry.isDirectory()?walk(p):[p];
  }):[];
}
const files=roots.flatMap(walk).filter((p)=>/\.(js|mjs|sql|json|md)$/.test(p));
const secretPatterns=[
  {name:'OpenAI secret',re:/\bsk-[A-Za-z0-9_-]{20,}\b/g},
  {name:'Stripe live secret',re:/\bsk_live_[A-Za-z0-9]{16,}\b/g},
  {name:'Supabase service JWT',re:/\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b/g},
  {name:'Database URL credentials',re:/postgres(?:ql)?:\/\/[^\s:'"]+:[^\s@'"]+@[^\s'"]+/gi},
  {name:'Private key',re:/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g},
];
const leaks=[];
for(const file of files){
  const c=fs.readFileSync(file,'utf8');
  for(const p of secretPatterns){
    for(const match of c.matchAll(p.re))leaks.push({file,type:p.name,sample:match[0].slice(0,24)});
  }
  if(/^['"]use client['"];?/m.test(c)){
    assert.ok(!c.includes('SUPABASE_SERVICE_ROLE_KEY'),`${file}: service-role credential reference in client bundle`);
    assert.ok(!c.includes('OPENAI_API_KEY'),`${file}: AI secret reference in client bundle`);
    assert.ok(!c.includes('DATABASE_URL'),`${file}: database credential reference in client bundle`);
  }
}
assert.deepEqual(leaks,[],'committed secret-like values detected: '+JSON.stringify(leaks));

const storage=fs.readFileSync('lib/server-storage.js','utf8');
const rate=fs.readFileSync('lib/rate-limit.js','utf8');
assert.ok(storage.includes("process.env.SUPABASE_SERVICE_ROLE_KEY"),'storage service-role use must remain server environment managed');
assert.ok(rate.includes("process.env.SUPABASE_SERVICE_ROLE_KEY"),'rate limiter service-role use must remain server environment managed');
assert.ok(!storage.startsWith("'use client'")&&!rate.startsWith("'use client'"));

const supabaseApi=fs.readFileSync('lib/supabase-api.js','utf8');
assert.ok(supabaseApi.includes('XZRECRUITER_SUPABASE_URL')&&supabaseApi.includes('XZRECRUITER_SUPABASE_PUBLISHABLE_KEY'),'Supabase backend must be explicitly environment configured');
assert.ok(supabaseApi.includes("throw new Error('xzrecruiter_supabase_not_configured')"),'missing Supabase configuration must fail closed');
assert.ok(!/https:\/\/[a-z0-9]{20}\.supabase\.co/i.test(supabaseApi),'hard-coded Supabase project URL is forbidden in runtime source');

const aiServerCandidates=files.filter((f)=>/ai-server|candidate-ai-server|jd-ai-server/i.test(f));
for(const file of aiServerCandidates){
  const c=fs.readFileSync(file,'utf8');
  if(c.includes('OPENAI_API_KEY'))assert.ok(!/^['"]use client['"];?/m.test(c),`${file}: AI key usage must be server only`);
}

console.log(`STEP7_SECRET_SECURITY_PASS scanned_files=${files.length} committed_secret_patterns=0 client_secret_refs=0`);
