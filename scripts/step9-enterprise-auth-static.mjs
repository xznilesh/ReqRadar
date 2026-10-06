import assert from 'node:assert/strict';
import fs from 'node:fs';

const route=fs.readFileSync('app/api/admin/sessions/route.js','utf8');
const helper=fs.readFileSync('lib/admin-sessions.js','utf8');
const step7=fs.readFileSync('supabase/migrations/20260928_step7_enterprise_multitenant_security_foundation.sql','utf8');

for(const token of [
  "['OWNER','ADMIN']",
  'mutationRequestIsTrusted',
  'currentWorkspaceSessionId',
  'listWorkspaceSessions',
  'revokeWorkspaceSession',
  "device_metadata:false"
])assert.ok(route.includes(token),'admin session route missing security contract '+token);

for(const token of [
  'SUPABASE_SERVICE_ROLE_KEY',
  "select:'id,user_id,agency_id,expires_at,revoked_at'",
  "agency_id:`eq.${agency}`",
  "method:'PATCH'",
  "action:'auth.session_revoked'",
  "prefer:'return=representation'"
])assert.ok(helper.includes(token),'admin session helper missing security contract '+token);

assert.ok(!helper.includes("select:'token_hash"),'session inventory must never select token hashes for response');
assert.ok(!route.includes('SUPABASE_SERVICE_ROLE_KEY'),'service role must stay outside HTTP route module');

for(const token of [
  'xzrecruiter_membership_session_guard',
  'xzrecruiter_disabled_user_session_guard',
  "set revoked_at=coalesce(revoked_at,now())",
  "s.revoked_at is null",
  "s.expires_at>now()"
])assert.ok(step7.includes(token),'existing session revocation invariant missing '+token);

console.log('STEP9_SESSION_ADMIN_STATIC_PASS owner_admin_only=true workspace_scoped=true targeted_revoke=true audit=true token_hash_hidden=true auto_revoke=true device_metadata=false');
