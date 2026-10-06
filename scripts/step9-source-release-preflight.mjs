import {spawnSync} from 'node:child_process';

const checks=[
  ['migration_repository_audit','node',['scripts/step9-repository-audit.mjs','--release']],
  ['enterprise_capability_audit','node',['scripts/step9-enterprise-capability-audit.mjs']]
];
const failed=[];
for(const [name,command,args] of checks){
  console.log('SOURCE_RELEASE_CHECK_START '+name);
  const result=spawnSync(command,args,{stdio:'inherit',env:process.env});
  if(result.status!==0)failed.push(name);
  console.log('SOURCE_RELEASE_CHECK_END '+name+' status='+(result.status??'signal'));
}
if(failed.length){
  console.error('SOURCE_RELEASE_BLOCKED '+JSON.stringify(failed));
  process.exit(2);
}
console.log('SOURCE_RELEASE_PREFLIGHT_PASS migrations=true enterprise_capabilities=true');
