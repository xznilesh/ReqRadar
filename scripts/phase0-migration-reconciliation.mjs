import assert from 'node:assert/strict';
import fs from 'node:fs';

const manifest=JSON.parse(fs.readFileSync('docs/phase0-production-migration-history.json','utf8'));
const local=fs.readdirSync('supabase/migrations').filter(x=>x.endsWith('.sql')).sort();
const remote=manifest.migrations;
assert.equal(remote.length,61,'audited production history count changed; recapture before release');

const byOriginalName=new Map(local.map(file=>[file.replace(/\.sql$/,''),file]));
const mapped=[];
const missing=[];
for(const m of remote){
  const canonical=m.version+'_'+m.name+'.sql';
  const original=m.name+'.sql';
  if(local.includes(canonical)) mapped.push({version:m.version,file:canonical,mode:'canonical'});
  else if(byOriginalName.has(m.name)) mapped.push({version:m.version,file:original,mode:'legacy-name'});
  else missing.push({version:m.version,name:m.name});
}
const versions=new Map();
for(const file of local){
 const version=file.split('_')[0];
 versions.set(version,[...(versions.get(version)||[]),file]);
}
const collisions=[...versions.entries()].filter(([,files])=>files.length>1);
console.log('PHASE0_MIGRATION_RECONCILIATION local='+local.length+' remote='+remote.length+' mapped='+mapped.length+' missing='+missing.length+' collisions='+collisions.length);
if(missing.length) console.log('PHASE0_MIGRATION_MISSING '+JSON.stringify(missing));
if(collisions.length) console.log('PHASE0_MIGRATION_COLLISIONS '+JSON.stringify(collisions));
if(process.argv.includes('--release')){
 assert.equal(missing.length,0,'production-applied migrations are missing locally');
 assert.equal(collisions.length,0,'local migration versions still collide');
 assert.ok(mapped.every(x=>x.mode==='canonical'),'all production migrations must use canonical applied versions');
}
