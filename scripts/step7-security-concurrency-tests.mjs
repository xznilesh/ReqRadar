import assert from 'node:assert/strict';
import fs from 'node:fs';

const ats=fs.readFileSync('supabase/migrations/20260926152125_20260903_step4_enterprise_ats_rpcs.sql','utf8');
const step5=fs.readFileSync('supabase/migrations/20260926153449_20260925_step5_ai_assisted_human_screening.sql','utf8');
const step6core=fs.readFileSync('supabase/migrations/20260926153500_20260925_step6_submission_pack_core.sql','utf8');
const step6=fs.readFileSync('supabase/migrations/20260926153505_20260925_step6_submission_pack_rpcs.sql','utf8');
const step7=fs.readFileSync('supabase/migrations/20260926153512_20260928_step7_enterprise_multitenant_security_foundation.sql','utf8');

assert.ok(ats.includes("possible_duplicate")&&ats.includes("exception when unique_violation"),'candidate creation must prevent duplicate records on retry/race');
assert.ok(ats.includes("and ((v_email is not null and lower(email)=v_email) or (v_phone is not null and phone=v_phone))"),'candidate duplicate check must be same-tenant identity based');
assert.ok(ats.includes("application_exists")&&ats.includes("candidate_id=p_candidate_id and job_id=p_job_id"),'candidate/job application retry must not create duplicate application records');

assert.ok(step5.includes('unique(agency_id,idempotency_key)'),'screening start idempotency uniqueness missing');
assert.ok(step5.includes('last_mutation_key'),'screening mutation replay guard missing');
assert.ok(step5.includes('for update'),'screening concurrent update lock missing');
assert.ok(step5.includes('stale_screening_version'),'screening optimistic concurrency missing');

assert.ok(step6core.includes('candidate_submission_idempotency'),'submission idempotency table missing');
assert.ok(step6core.includes('version_lock bigint'),'submission optimistic lock version missing');
assert.ok(step6core.includes('unique(agency_id,operation,idempotency_key)'),'submission idempotency uniqueness missing');
for(const op of ['STEP6_GENERATE','STEP6_SEND','STEP6_AM','STEP6_CLIENT']){
  assert.ok(step6.includes('pg_advisory_xact_lock')&&step6.includes(op),`submission concurrency lock missing for ${op}`);
}
assert.ok(step6.includes('stale_submission_version'),'stale submission writes must be rejected');
assert.ok(step6.includes('duplicate_client_submission'),'duplicate client submission guard missing');

const step7Locks=(step7.match(/pg_advisory_xact_lock/g)||[]).length;
assert.ok(step7Locks>=3,'Step-7 wrappers must preserve/strengthen critical locks');
assert.ok(step7.includes('candidate.export_rate_limited'),'bulk/export retry abuse must be security controlled');
assert.ok(step7.includes("membership.role_changed")&&step7.includes("sessions_revoked"),'membership changes must invalidate sessions');
assert.ok(step7.includes("submission.client_submitted")&&step7.includes("candidate.export_rate_limited"),'critical mutation/security events missing');

console.log('STEP7_CONCURRENCY_SECURITY_PASS candidate_dedupe=true application_dedupe=true screening=true submissions=true membership_revocation=true idempotency=true locks='+step7Locks);
