import fs from 'node:fs';

function read(file){return fs.existsSync(file)?fs.readFileSync(file,'utf8'):null}
function exactCheck({name,files,tokens=[]}){
  const contents=files.map(file=>({file,text:read(file)}));
  const missingFiles=contents.filter(x=>x.text===null).map(x=>x.file);
  const joined=contents.filter(x=>x.text!==null).map(x=>x.text).join('\n');
  const missingTokens=tokens.filter(token=>!joined.includes(token));
  return {
    name,
    implemented:missingFiles.length===0&&missingTokens.length===0,
    files:contents.filter(x=>x.text!==null).map(x=>x.file),
    missing_files:missingFiles,
    missing_tokens:missingTokens
  };
}

const checks=[
  exactCheck({
    name:'enterprise_auth_sso',
    files:['app/api/auth/sso/route.js','app/api/auth/sso/callback/route.js'],
    tokens:['signInWithSSO','auth/v1/sso','state']
  }),
  exactCheck({
    name:'enterprise_auth_mfa',
    files:['app/api/auth/mfa/enroll/route.js','app/api/auth/mfa/verify/route.js'],
    tokens:['aal2','factor']
  }),
  exactCheck({
    name:'enterprise_auth_scim',
    files:['app/api/scim/v2/Users/route.js','lib/scim.js'],
    tokens:['SCIM','active','agency_id']
  }),
  exactCheck({
    name:'enterprise_auth_admin_session_management',
    files:['app/api/admin/sessions/route.js','lib/admin-sessions.js'],
    tokens:['OWNER','ADMIN','revokeWorkspaceSession','auth.session_revoked','token_hash']
  }),

  exactCheck({
    name:'privacy_dsar_export',
    files:['app/api/compliance/dsar-export/route.js'],
    tokens:['DATA_SUBJECT_ACCESS','candidateConsentHistory','Content-Disposition']
  }),
  exactCheck({
    name:'privacy_retention_executor',
    files:['scripts/retention-executor.mjs','lib/retention-policy.js'],
    tokens:['legal_hold','retention','delete']
  }),
  exactCheck({
    name:'privacy_consent_history',
    files:['lib/compliance-data.js','app/api/compliance/dsar-export/route.js'],
    tokens:['candidateConsentHistory','candidate.consent_changed','history_available']
  }),
  exactCheck({
    name:'privacy_ai_decision_export',
    files:['app/api/compliance/ai-decision-export/route.js'],
    tokens:['AI_DECISION_EXPORT_VERSION','automated_final_decision:false','human_review_export']
  }),

  exactCheck({
    name:'integration_google',
    files:['lib/integrations/google.js','app/api/integrations/google/callback/route.js'],
    tokens:['googleapis.com','oauth']
  }),
  exactCheck({
    name:'integration_microsoft',
    files:['lib/integrations/microsoft.js','app/api/integrations/microsoft/callback/route.js'],
    tokens:['graph.microsoft.com','oauth']
  }),
  exactCheck({
    name:'integration_webhook_security',
    files:['lib/integrations/webhooks.js'],
    tokens:['HMAC','signature','replay']
  }),
  exactCheck({
    name:'integration_api_key_lifecycle',
    files:['lib/integrations/api-keys.js'],
    tokens:['hash','rotate','revoke']
  }),

  exactCheck({
    name:'operations_structured_telemetry',
    files:['lib/telemetry.js','instrumentation.js','docs/runbooks/production-incident-response.md'],
    tokens:['telemetryError','onRequestError','incident']
  })
];

const missing=checks.filter(x=>!x.implemented);
console.log('ENTERPRISE_CAPABILITY_AUDIT '+JSON.stringify({
  implemented:checks.filter(x=>x.implemented).map(x=>x.name),
  missing:missing.map(x=>x.name)
}));
for(const result of checks){
  console.log(
    'ENTERPRISE_CAPABILITY_CHECK '+result.name+'='+(result.implemented?'PASS':'MISSING')+
    (result.files.length?' files='+result.files.join(','):'')+
    (result.missing_files.length?' missing_files='+result.missing_files.join(','):'')+
    (result.missing_tokens.length?' missing_tokens='+result.missing_tokens.join(','):'')
  );
}
if(missing.length)process.exit(2);
console.log('ENTERPRISE_CAPABILITY_AUDIT_PASS all_required_source_capabilities=true');
