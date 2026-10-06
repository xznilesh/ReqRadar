import assert from 'node:assert/strict';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { sortPriorityRequirements } from '../lib/recruiter-execution.mjs';

const sql=fs.readFileSync('supabase/migrations/20260926152551_20260926_step3_recruiter_execution_workspace.sql','utf8');
const workspace=fs.readFileSync('app/components/RecruiterRequirementWorkspace.js','utf8');

for(const index of [
  'idx_xzr_requirement_assignments_recruiter',
  'idx_xzr_requirement_assignments_job',
  'idx_xzr_applications_recruiter_queue',
  'idx_xzr_recruiter_tasks_due',
  'idx_xzr_recruiter_tasks_job'
])assert.ok(sql.includes(index),'missing performance index '+index);

assert.ok(sql.includes('least(coalesce(p_limit,50),100)'),'dashboard/queue limit missing');
assert.ok(sql.includes('least(coalesce(p_limit,20),30)'),'candidate search limit missing');
assert.ok(sql.includes('limit 30'),'task list bound missing');
assert.ok(sql.includes('limit 20'),'interview/search bound missing');
assert.ok(sql.includes('limit 50'),'role task/queue bound missing');
assert.ok(workspace.includes('search.trim().length<2'),'candidate search should not fire on empty query');
assert.ok(!workspace.includes('/api/ats?module=CANDIDATES'),'browser must not load entire candidate DB');
const syntheticRoles=Array.from({length:1000},(_,i)=>({title:'Role '+i,remaining_target:i%8,priority:['LOW','NORMAL','HIGH','URGENT'][i%4],target_fill_date:'2026-10-'+String((i%28)+1).padStart(2,'0'),age_hours:i%240,pipeline_candidates:i%30,blocker_count:i%3===0?1:0}));
const started=performance.now();
const sorted=sortPriorityRequirements(syntheticRoles,new Date('2026-09-26T08:00:00Z'));
const elapsed=performance.now()-started;
assert.equal(sorted.length,1000);
assert.ok(elapsed<1000,'1000-role deterministic priority ordering should remain sub-second in CI');
console.log('STEP3_EXECUTION_PERFORMANCE_PASS indexes=true bounded_lists=true pagination_contract=true search_server_side=true synthetic_roles=1000 sort_ms='+elapsed.toFixed(2));
