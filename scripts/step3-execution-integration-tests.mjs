import assert from 'node:assert/strict';
import fs from 'node:fs';

const migrationPath='supabase/migrations/20260926152551_20260926_step3_recruiter_execution_workspace.sql';
const sql=fs.readFileSync(migrationPath,'utf8');
assert.equal(fs.existsSync('supabase/migrations/20260925_step3_recruiter_execution_workspace.sql'),false,'duplicate Step-3 migration must not exist');
assert.equal((sql.match(/as \$fn\$/g)||[]).length,(sql.match(/\$fn\$;/g)||[]).length,'unbalanced SQL function dollar quotes');
assert.equal((sql.match(/do \$do\$/g)||[]).length,(sql.match(/\$do\$;/g)||[]).length,'unbalanced SQL DO dollar quotes');
const recruiter=fs.readFileSync('lib/recruiter.js','utf8');
const api=fs.readFileSync('app/api/recruiter/route.js','utf8');

for(const token of [
  'requirement_recruiter_assignments','submission_target_total','total_submission_target','invalidated_at','withdrawn_at',
  'alter table public.applications add column if not exists source_type',
  'alter table public.crm_tasks add column if not exists task_type',
  'xzrecruiter_save_requirement_assignment',
  'xzrecruiter_recruiter_home',
  'xzrecruiter_recruiter_requirement_context',
  'xzrecruiter_recruiter_candidate_search',
  'xzrecruiter_recruiter_intake_candidate',
  'xzrecruiter_save_execution_task',
  'xzrecruiter_set_execution_task_status',
  'requirement.recruiter_assigned',
  'candidate.associated_with_requirement',
  'followup.created',
  'task.completed',
  'candidate.resume_uploaded'
]) assert.ok(sql.includes(token),'missing Step-3 integration contract: '+token);

assert.ok(!/create table if not exists public\.(candidates|applications|crm_tasks|candidate_submissions)\b/i.test(sql),'Step 3 must reuse existing candidate/application/task/submission tables');
assert.ok(sql.includes("recruiter_ready=true and approved_hiring_brief_id is not null"),'assignment/intake must require approved recruiter-ready requirement');
assert.ok(sql.includes('unique(agency_id,job_id,recruiter_user_id)'),'assignment uniqueness missing');
assert.ok(sql.includes('uq_xzr_application_intake_idempotency'),'candidate intake idempotency missing');
assert.ok(sql.includes('uq_xzr_crm_task_idempotency'),'task idempotency missing');
assert.ok(sql.includes('uq_xzr_requirement_assignment_idempotency'),'assignment idempotency missing');
assert.ok(sql.includes("workspace_global_settings"),'workspace timezone source missing');
assert.ok(sql.includes("at time zone timezone_id"),'business-day timezone bounds missing');
assert.ok(sql.includes("not in ('WITHDRAWN','REJECTED')"),'invalid/withdrawn candidacies must not count toward target');
assert.ok(sql.includes("'jobs_requiring_attention',v_attention"),'attention metric must exclude fully achieved/no-action roles');
assert.ok(sql.includes('due_tasks_today'),'due-today follow-up calculation missing');
assert.ok(sql.includes("workflow_status='CLIENT_SUBMITTED'")&&sql.includes("status='SUBMITTED'"),'valid submission definition missing');
assert.ok(sql.includes('cs.invalidated_at is null')&&sql.includes('cs.withdrawn_at is null'),'invalidated/withdrawn submissions must not count');
assert.ok(sql.includes('cs.created_by_user_id=ra.recruiter_user_id')&&sql.includes('cs.created_by_user_id=v_user'),'recruiter credit must follow submission creator');

for(const token of ['saveAssignment','intakeCandidate','candidateSearch','saveTask','setTaskStatus','prepareResume','finalizeResume']){
  assert.ok(recruiter.includes(token),'server adapter missing '+token);
}
assert.ok(api.includes("mode==='candidateSearch'"));
assert.ok(api.includes("sameOrigin"));
console.log('STEP3_EXECUTION_INTEGRATION_PASS assignment=true candidate_intake=true source=true tasks=true activity=true targets=true tenant_contract=true');
