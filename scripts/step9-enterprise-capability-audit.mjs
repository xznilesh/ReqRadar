import fs from 'node:fs';
import path from 'node:path';

function walk(dir){
  if(!fs.existsSync(dir))return [];
  return fs.readdirSync(dir,{withFileTypes:true}).flatMap(entry=>{
    const p=path.join(dir,entry.name);
    return entry.isDirectory()?walk(p):[p];
  });
}
const implementationFiles=[
  ...walk('app'),
  ...walk('lib'),
  ...walk('supabase/functions'),
  ...walk('scripts').filter(p=>/(compliance|retention|connector|webhook|telemetry|session|scim|sso|mfa)/i.test(p))
].filter(p=>/\.(js|mjs|ts|tsx|sql)$/.test(p)&&!/(test|fixture|audit)/i.test(path.basename(p)));
const sources=implementationFiles.map(file=>({file,text:fs.readFileSync(file,'utf8')}));

function matching(pattern,pathPattern=null){
  return sources.filter(({file,text})=>(!pathPattern||pathPattern.test(file))&&pattern.test(text)).map(x=>x.file);
}
const checks=[
  ['enterprise_auth_sso',/(signInWithSSO|\/auth\/v1\/sso|saml)/i,/^(app|lib)[/\\]/],
  ['enterprise_auth_mfa',/(auth\.mfa|\/auth\/v1\/factors|aal2|totp)/i,/^(app|lib)[/\\]/],
  ['enterprise_auth_scim',/(scim\/v2|scim.*provision|provision.*scim)/i,/^(app|lib|supabase\/functions)[/\\]/],
  ['enterprise_auth_admin_session_management',/(admin.{0,80}(session|device).{0,80}(revoke|terminate)|(revoke|terminate).{0,80}(session|device))/i,/^(app|lib)[/\\]/],

  ['privacy_dsar_export',/(dsar|data subject access|subject_access_request)/i,/^(app|lib|scripts)[/\\]/],
  ['privacy_retention_executor',/(retention.{0,120}(delete|purge|expire)|(?:delete|purge).{0,120}retention)/i,/^(app|lib|scripts)[/\\]/],
  ['privacy_consent_history',/(consent.{0,120}(history|event|record|notice)|notice.{0,120}consent)/i,/^(app|lib)[/\\]/],
  ['privacy_ai_decision_export',/(ai.{0,120}(decision|recommendation).{0,120}(export|explain)|human.{0,80}(review|override).{0,120}export)/i,/^(app|lib|scripts)[/\\]/],

  ['integration_google',/(accounts\.google\.com|googleapis\.com|google.{0,80}(oauth|calendar|gmail))/i,/^(app|lib|supabase\/functions)[/\\]/],
  ['integration_microsoft',/(login\.microsoftonline\.com|graph\.microsoft\.com|microsoft.{0,80}(oauth|calendar|outlook))/i,/^(app|lib|supabase\/functions)[/\\]/],
  ['integration_webhook_security',/(webhook.{0,120}(hmac|signature|signing)|verify.{0,80}webhook)/i,/^(app|lib|supabase\/functions)[/\\]/],
  ['integration_api_key_lifecycle',/(api.?key.{0,120}(hash|rotate|revoke|prefix)|(rotate|revoke).{0,120}api.?key)/i,/^(app|lib|supabase\/functions)[/\\]/],

  ['operations_structured_telemetry',/(telemetry|opentelemetry|traceparent|structured.{0,40}(log|event))/i,/^(app|lib|supabase\/functions)[/\\]/]
];

const results=checks.map(([name,pattern,pathPattern])=>{
  const files=matching(pattern,pathPattern);
  return {name,implemented:files.length>0,files};
});
const missing=results.filter(x=>!x.implemented);
console.log('ENTERPRISE_CAPABILITY_AUDIT '+JSON.stringify({implemented:results.filter(x=>x.implemented).map(x=>x.name),missing:missing.map(x=>x.name)}));
for(const result of results)console.log('ENTERPRISE_CAPABILITY_CHECK '+result.name+'='+(result.implemented?'PASS':'MISSING')+(result.files.length?' files='+result.files.join(','):''));
if(missing.length)process.exit(2);
console.log('ENTERPRISE_CAPABILITY_AUDIT_PASS all_required_source_capabilities=true');
