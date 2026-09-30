import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const strict=process.argv.includes('--release');
const migrationDir='supabase/migrations';
const migrationPath=(logicalName)=>{
 const matches=fs.readdirSync(migrationDir).filter(f=>f.endsWith(`_${logicalName}.sql`));
 assert.equal(matches.length,1,'expected exactly one canonical migration for '+logicalName);
 return path.join(migrationDir,matches[0]);
};
function walk(dir){return fs.existsSync(dir)?fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>{const p=path.join(dir,e.name);return e.isDirectory()?walk(p):[p]}):[]}
const required=[
 'docs/step1-workflow-contract.md',
 migrationPath('step1_workflow_contract_lock'),
 migrationPath('step2_ai_jd_brain'),
 migrationPath('step3_recruiter_execution_workspace'),
 migrationPath('step4_candidate_intelligence_core'),
 migrationPath('step5_ai_assisted_human_screening'),
 migrationPath('step6_submission_pack_core'),
 migrationPath('step7_enterprise_multitenant_security_foundation'),
 migrationPath('step8_automation_manager_core'),
 'app/api/health/ready/route.js','app/api/requirements/jd/route.js','app/api/candidate-intelligence/route.js',
 'app/api/submissions/route.js','app/api/automation/run/route.js','app/api/manager-control/route.js',
 'tests/fixtures/jd-regression.json','tests/fixtures/candidate-intelligence-regression.json','tests/fixtures/step5-screening.json','tests/fixtures/submission-pack-regression.json'
];
for(const p of required)assert.ok(fs.existsSync(p),'missing locked-roadmap source '+p);

const files=walk('.').filter(p=>!p.startsWith('node_modules')&&!p.startsWith('.git')&&!p.startsWith('.next')&&!p.startsWith('test-results'));
const textFiles=files.filter(p=>/.(js|mjs|json|yml|yaml|sql|md|css)$/.test(p));
const conflict=[];
const leaks=[];
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

const migrations=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql')).sort();
const versions=new Map();
for(const file of migrations){
 const version=file.split('_')[0];
 if(!versions.has(version))versions.set(version,[]);
 versions.get(version).push(file);
}
const duplicateVersions=[...versions.entries()].filter(([,v])=>v.length>1);
const apiRoutes=walk('app/api').filter(p=>p.endsWith('route.js')).length;
const pkg=JSON.parse(fs.readFileSync('package.json','utf8'));
for(const layer of ['unit','integration','e2e','security','ai','performance'])assert.ok(pkg.scripts['test:step9:'+layer],'missing Step-9 layer '+layer);
assert.ok(!Object.keys(pkg.scripts).some(k=>/step10/i.test(k)),'Step 10 must not exist');

console.log('STEP9_REPOSITORY_AUDIT source_files='+textFiles.length+' api_routes='+apiRoutes+' migrations='+migrations.length+' conflicts=0 secret_patterns=0');
if(duplicateVersions.length){
 console.log('STEP9_AUDIT_P0 duplicate_migration_versions='+duplicateVersions.map(([v,a])=>v+':'+a.length).join(','));
 if(strict)process.exit(2);
}
