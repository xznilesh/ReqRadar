import assert from 'node:assert/strict';
import fs from 'node:fs';
import {performance} from 'node:perf_hooks';
import {hasPermission} from '../lib/security-policy.mjs';

const s=fs.readFileSync('supabase/migrations/20260926153512_20260928_step7_enterprise_multitenant_security_foundation.sql','utf8');
for(const token of [
  'idx_xzr_memberships_active_user',
  'idx_xzr_sessions_active_workspace',
  'idx_xzr_security_events_agency_time',
  'idx_xzr_security_events_type_time',
  'idx_xzr_rate_limit_updated',
  'idx_xzr_security_rate_limit_window'
])assert.ok(s.includes(token),'security performance index missing: '+token);

const loops=100000;
const started=performance.now();
for(let i=0;i<loops;i++){
  hasPermission(i%2?'RECRUITER':'ACCOUNT_MANAGER',i%3?'candidate:view':'submission:client_submit');
}
const ms=performance.now()-started;
assert.ok(ms<1000,`100k in-process capability checks should be sub-second; got ${ms.toFixed(2)}ms`);

assert.ok(s.includes('limit v_limit'),'security event query must be bounded');
assert.ok(s.includes('v_limit integer:=least(greatest(coalesce(p_limit,100),1),500)'),'security event maximum page bound missing');

console.log(`STEP7_SECURITY_PERFORMANCE_PASS capability_checks=${loops} ms=${ms.toFixed(2)} indexes=true bounded_security_events=true`);
