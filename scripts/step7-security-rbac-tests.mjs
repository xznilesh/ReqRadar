import assert from 'node:assert/strict';
import fs from 'node:fs';
import {ROLE_PERMISSIONS,canonicalRole,hasPermission,permissionForDocument,DATA_CLASSIFICATION} from '../lib/security-policy.mjs';

assert.equal(canonicalRole('BDM'),'ACCOUNT_MANAGER');
assert.equal(canonicalRole('BUSINESS_DEVELOPMENT'),'ACCOUNT_MANAGER');
assert.equal(canonicalRole('SOURCER'),'RECRUITER');

assert.equal(hasPermission('OWNER','anything:future'),true);
assert.equal(hasPermission('ADMIN','team:manage'),true);
assert.equal(hasPermission('RECRUITER','submission:create'),true);
assert.equal(hasPermission('RECRUITER','submission:client_submit'),false);
assert.equal(hasPermission('RECRUITER','commercial:view'),false);
assert.equal(hasPermission('ACCOUNT_MANAGER','submission:am_review'),true);
assert.equal(hasPermission('ACCOUNT_MANAGER','submission:client_submit'),true);
assert.equal(hasPermission('COMPLIANCE_REVIEWER','document:sensitive_view'),true);
assert.equal(hasPermission('CLIENT_USER','candidate:view'),false);

assert.equal(permissionForDocument({documentType:'RESUME',classification:'HIGHLY_SENSITIVE'}),'document:resume_view');
assert.equal(permissionForDocument({documentType:'PASSPORT',classification:'HIGHLY_SENSITIVE'}),'document:sensitive_view');
assert.ok(Object.values(DATA_CLASSIFICATION).includes('HIGHLY_SENSITIVE'));

const sql=fs.readFileSync('supabase/migrations/20260926153512_20260928_step7_enterprise_multitenant_security_foundation.sql','utf8');
const pairs=[
  ['RECRUITMENT_MANAGER','candidate:screen'],
  ['RECRUITMENT_MANAGER','requirement:assign'],
  ['ACCOUNT_MANAGER','submission:am_review'],
  ['ACCOUNT_MANAGER','commercial:edit'],
  ['RECRUITER','document:resume_view'],
  ['COMPLIANCE_REVIEWER','document:sensitive_view'],
];
for(const [role,perm] of pairs){
  assert.ok((ROLE_PERMISSIONS[role]||[]).includes(perm),`JS policy missing ${role} -> ${perm}`);
  const start=sql.indexOf(`when '${role}'`);
  assert.ok(start>=0&&sql.slice(start,start+1300).includes(perm),`DB policy missing ${role} -> ${perm}`);
}
for(const denied of [
  ['RECRUITER','commercial:view'],['RECRUITER','submission:am_review'],
  ['RECRUITER','document:sensitive_view'],['CLIENT_USER','candidate:view']
])assert.equal(hasPermission(...denied),false,`unexpected privilege ${denied.join(' -> ')}`);

console.log('STEP7_RBAC_SECURITY_PASS centralized_policy=true db_js_parity=true least_privilege=true');
