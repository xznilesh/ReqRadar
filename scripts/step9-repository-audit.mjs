import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const strict=process.argv.includes('--release');
function walk(dir){return fs.existsSync(dir)?fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>{const p=path.join(dir,e.name);return e.isDirectory()?walk(p):[p]}):[]}
const required=[
 'docs/step1-workflow-contract.md',
 'supabase/migrations/20260925_step1_workflow_contract_lock.sql',
 'supabase/migrations/20260925_step2_ai_jd_brain.sql',
 'supabase/migrations/20260926_step3_recruiter_execution_workspace.sql',
 'supabase/migrations/20260927_step4_candidate_intelligence_core.sql',
 'supabase/migrations/20260925_step5_ai_assisted_human_screening.sql',
 'supabase/migrations/20260925_step6_submission_pack_core.sql',
 'supabase/migrations/20260928_step7_enterprise_multitenant_security_foundation.sql',
 'supabase/migrations/20260929_step8_automation_manager_core.sql',
 'app/api/health/ready/route.js','app/api/requirements/jd/route.js','app/api/candidate-intelligence/route.js',
 'app/api/submissions/route.js','app/api/automation/run/route.js','app/api/manager-control/route.js',
 'tests/fixtures/jd-regression.json','tests/fixtures/candidate-intelligence-regression.json','tests/fixtures/step5-screening.json','tests/fixtures/submission-pack-regression.json',
 'package-lock.json','scripts/enterprise-browser-e2e.mjs','scripts/step9-tenant-isolation-live.mjs','scripts/step9-postgres-load.mjs','scripts/step9-postgres-load.sql'
];
for(const p of required)assert.ok(fs.existsSync(p),'missing release source '+p);

const files=walk('.').filter(p=>!p.startsWith('node_modules')&&!p.startsWith('.git')&&!p.startsWith('.next')&&!p.startsWith('test-results'));
const textFiles=files.filter(p=>/\.(js|mjs|json|yml|yaml|sql|md|css)$/.test(p));
const conflict=[];const leaks=[];
const secretRules=[
 ['openai',/\bsk-[A-Za-z0-9_-]{20,}\b/g],['database',/postgres(?:ql)?:\/\/[^\s:'"]+:[^\s@'"]+@[^\s'"]+/gi],
 ['private_key',/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],['supabase_jwt',/\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b/g]
];
for(const file of textFiles){
 const c=fs.readFileSync(file,'utf8');
 if(file!=='scripts/step9-repository-audit.mjs'&&(c.includes('<<<<<<< ')||c.includes('>>>>>>> ')||c.includes('=======')))conflict.push(file);
 const scanned=c.replace(/postgresql:\/\/placeholder:placeholder@localhost:\d+\/postgres/g,'');
 for(const [name,re] of secretRules){re.lastIndex=0;if(re.test(scanned))leaks.push(file+':'+name);}
}
assert.deepEqual(conflict,[],'merge conflict markers remain');
assert.deepEqual(leaks,[],'secret-like committed material detected');

const pkg=JSON.parse(fs.readFileSync('package.json','utf8'));
const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
assert.equal(lock.lockfileVersion,3,'npm lockfile v3 required');
const root=lock.packages?.['']||{};
for(const group of ['dependencies','devDependencies']){
 const wanted=pkg[group]||{},locked=root[group]||{};
 assert.deepEqual(Object.keys(locked).sort(),Object.keys(wanted).sort(),`package-lock root ${group} set differs from package.json`);
 for(const [name,version] of Object.entries(wanted))assert.equal(locked[name],version,`lockfile mismatch for ${name}`);
}
for(const workflow of ['.github/workflows/verify.yml','.github/workflows/release-gate.yml','.github/workflows/deploy-production.yml']){
 const c=fs.readFileSync(workflow,'utf8');
 assert.ok(c.includes('npm ci --no-audit --no-fund'),workflow+' must use deterministic npm ci');
}

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql')).sort();
const versions=new Map();
for(const file of migrations){const version=file.split('_')[0];if(!versions.has(version))versions.set(version,[]);versions.get(version).push(file);}
const duplicateVersions=[...versions.entries()].filter(([,v])=>v.length>1);
const apiRoutes=walk('app/api').filter(p=>p.endsWith('route.js')).length;
for(const layer of ['unit','integration','e2e','security','ai','performance'])assert.ok(pkg.scripts['test:step9:'+layer],'missing Step-9 layer '+layer);
for(const script of ['test:step9:browser-live','test:step9:load-live','test:step9:tenant-isolation-live'])assert.ok(pkg.scripts[script],'missing enterprise live test script '+script);
assert.ok(!Object.keys(pkg.scripts).some(k=>/step10/i.test(k)),'Step 10 must not exist');
const vercel=JSON.parse(fs.readFileSync('vercel.json','utf8'));
assert.equal(vercel?.git?.deploymentEnabled,false,'Vercel native Git auto-deploy must remain disabled; production is CI-controlled');
const deployWorkflow=fs.readFileSync('.github/workflows/deploy-production.yml','utf8');
assert.ok(!deployWorkflow.includes('vercel@latest'),'Vercel CLI must be pinned, not latest');
assert.ok(deployWorkflow.includes('--skip-domain')&&deployWorkflow.includes('vercel promote'),'production must stage, certify, then promote the exact artifact');
assert.ok(deployWorkflow.includes('test:step9:tenant-isolation-live')&&deployWorkflow.includes('XZRECRUITER_TENANT_ISOLATION_EVIDENCE'),'production must certify live dual-tenant isolation');
const scanner=fs.readFileSync('lib/malware-scan.js','utf8');
assert.ok(scanner.includes("throw new Error('malware_scan_not_configured')"),'private uploads must fail closed when malware scanner is unavailable');

console.log('STEP9_REPOSITORY_AUDIT source_files='+textFiles.length+' api_routes='+apiRoutes+' migrations='+migrations.length+' conflicts=0 secret_patterns=0 deterministic_install=true malware_fail_closed=true git_autodeploy=false tenant_live_gate=true');
if(duplicateVersions.length){
 console.error('STEP9_AUDIT_P0 duplicate_migration_versions='+duplicateVersions.map(([v,a])=>v+':'+a.length).join(','));
 if(strict)process.exit(2);
}
