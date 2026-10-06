import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql=fs.readFileSync('supabase/migrations/20260926152551_20260926_step3_recruiter_execution_workspace.sql','utf8');
const api=fs.readFileSync('app/api/ats/route.js','utf8');
const recruiterApi=fs.readFileSync('app/api/recruiter/route.js','utf8');
const resumeApi=fs.readFileSync('app/api/recruiter/resume/route.js','utf8');
const workspace=fs.readFileSync('app/components/RecruiterRequirementWorkspace.js','utf8');

assert.ok(sql.includes('alter table public.requirement_recruiter_assignments enable row level security'));
assert.ok(sql.includes("policy xzrecruiter_data_api_deny"));
assert.ok((sql.match(/agency_id=v_agency/g)||[]).length>=30,'tenant scoping should be pervasive');
assert.ok(sql.includes("ra.recruiter_user_id=v_user")&&sql.includes("ra.assignment_status='ACTIVE'"),'assignment scope missing');
assert.ok(sql.includes('j.recruiter_ready=true')&&sql.includes("j.requirement_state='OPEN'")&&sql.includes('j.approved_hiring_brief_id is not null'),'recruiter access must stop when the approved requirement leaves recruiter-ready state');
assert.ok(sql.includes('j.recruiter_ready=true')&&sql.includes("j.requirement_state='OPEN'")&&sql.includes('j.approved_hiring_brief_id is not null'),'recruiter access must be revoked when Step-2 requirement is no longer approved/recruiter-ready');
assert.ok(sql.includes('requirement_access_forbidden'));
assert.ok(sql.includes('candidate_access_forbidden'));
assert.ok(sql.includes('recruiter_self_assignment_only'));
assert.ok(sql.includes('assignee_not_recruiter'));
assert.ok(sql.includes('protected_requirement'));
assert.ok(sql.includes('reusable_without_manager'),'privacy-safe internal talent discovery flag missing');
assert.ok(sql.includes("then c.email else null end email"),'unrelated candidate email should be masked');
assert.ok(sql.includes("then c.phone else null end phone"),'unrelated candidate phone should be masked');

for(const name of [
  'xzrecruiter_ats_context_step3_legacy','xzrecruiter_candidate_search_step3_legacy','xzrecruiter_job_search_step3_legacy',
  'xzrecruiter_save_job_step3_legacy','xzrecruiter_update_job_profile_step3_legacy',
  'xzrecruiter_save_candidate_step3_legacy','xzrecruiter_update_candidate_profile_step3_legacy',
  'xzrecruiter_candidate_document_access_step3_legacy'
]){
  assert.ok(sql.includes('revoke all on function public.'+name),'legacy implementation execute not revoked: '+name);
}
assert.ok(sql.includes("if v_guard->>'business_role'='RECRUITER' then return jsonb_build_object('ok',false,'error','execution_workspace_required')"));
assert.ok(api.includes('protectedForRecruiter'));
assert.ok(api.includes('execution_workspace_required'));
assert.ok(recruiterApi.includes('sameOrigin')&&resumeApi.includes('sameOrigin'));
assert.ok(resumeApi.includes('MAX_BYTES=8*1024*1024'));
assert.ok(!workspace.includes('AI candidate score'));
assert.ok(!workspace.includes('match score'));
assert.ok(!workspace.includes('AI fit'));
assert.ok(!/NEXT_PUBLIC_.*SERVICE_ROLE|OPENAI_API_KEY/.test(workspace));
console.log('STEP3_EXECUTION_SECURITY_PASS cross_tenant=true assignment_scope=true legacy_rpc_guard=true protected_requirements=true docs_scoped=true no_step4_scoring=true');
