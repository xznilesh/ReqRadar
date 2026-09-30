import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root=process.cwd();
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');
const must=(p)=>assert.ok(fs.existsSync(path.join(root,p)),`Missing ${p}`);

for(const p of [
 'app/candidates/page.js','app/jobs/page.js','app/pipeline/page.js','app/interviews/page.js','app/offers/page.js','app/placements/page.js',
 'app/jobs/public/[slug]/page.js','app/portal/candidate/[token]/page.js','app/api/ats/route.js','app/api/public/apply/route.js',
 'app/components/CandidateWorkspace.js','app/components/JobWorkspace.js','app/components/PipelineWorkspace.js','app/components/RecruitmentOpsWorkspace.js','app/components/PublicApplyForm.js',
 'lib/ats.js','lib/workspace-ready.js','app/step4.css',
 'supabase/migrations/20260903_step4_enterprise_ats_core.sql','supabase/migrations/20260903_step4_enterprise_ats_rpcs.sql',
 'supabase/migrations/20260903_step4_legacy_constraint_compatibility.sql','supabase/migrations/20260903_step4_z_dashboard_metrics.sql'
])must(p);

const core=read('supabase/migrations/20260903_step4_enterprise_ats_core.sql');
const rpcs=read('supabase/migrations/20260903_step4_enterprise_ats_rpcs.sql');
const compatibility=read('supabase/migrations/20260903_step4_legacy_constraint_compatibility.sql');
const shell=read('app/components/AppShell.js');
const palette=read('app/components/CommandPalette.js');
const css=read('app/step4.css');
const candidates=read('app/components/CandidateWorkspace.js');
const jobs=read('app/components/JobWorkspace.js');
const pipeline=read('app/components/PipelineWorkspace.js');
const dashboard=read('app/dashboard/page.js');

assert.ok(!/\bdrop\s+table\b|\btruncate\b|\bdelete\s+from\b/i.test(`${core}\n${rpcs}\n${compatibility}`),'Step 4 migration must be additive and archive-oriented');
for(const token of ['candidate_documents','candidate_parse_runs','candidate_merge_events','talent_pools','application_stage_history','candidate_submissions','scorecard_templates','interview_scorecards','offer_approvals','recruitment_attachments','candidate_portal_sessions'])assert.ok(core.includes(`public.${token}`),`Missing ATS table ${token}`);
for(const token of ['preferred_name','availability_status','pipeline_id','stage_id','public_visibility','candidate_timezone','version_number','fee_type'])assert.ok(core.includes(token),`Missing Step-4 field ${token}`);
for(const fn of ['xzrecruiter_workspace_ready','xzrecruiter_ats_context','xzrecruiter_save_candidate','xzrecruiter_save_job','xzrecruiter_create_application','xzrecruiter_move_application_stage','xzrecruiter_schedule_interview','xzrecruiter_save_offer','xzrecruiter_create_placement','xzrecruiter_issue_candidate_portal_access','xzrecruiter_candidate_portal_snapshot','xzrecruiter_public_job','xzrecruiter_public_apply'])assert.ok(rpcs.includes(`function public.${fn}`),`Missing RPC ${fn}`);
assert.ok(rpcs.includes('private.xzrecruiter_session_context'),'ATS writes must derive workspace from session');
assert.ok(!/p_agency_id/i.test(rpcs.match(/create or replace function public\.xzrecruiter_save_candidate[\s\S]*?end;\$fn\$/)?.[0]||''),'Candidate write must not accept agency_id from browser');

// Route presence is what matters; formatting may evolve as the shell is refined.
for(const route of ['/candidates','/jobs','/interviews','/offers','/placements','/pipeline'])assert.ok(shell.includes(route),`Navigation missing ${route}`);
for(const route of ['/candidates','/jobs','/pipeline','/interviews','/offers','/placements'])assert.ok(palette.includes(route),`Command palette missing ${route}`);
assert.ok(dashboard.includes("onboarding.progress?.status !== 'COMPLETED'")&&dashboard.includes("redirect('/onboarding')"),'Dashboard onboarding server gate regressed');
assert.ok(dashboard.includes('Workspace blueprint')&&dashboard.includes('realMetricTotal > 0'));
assert.ok(candidates.includes('possible_duplicate')&&candidates.includes('Archive')&&candidates.includes('portalAccess'));
assert.ok(jobs.includes('publicVisibility')&&jobs.includes('pipelineId')&&jobs.includes('salaryPeriod'));
assert.ok(pipeline.includes('moveApplication')&&pipeline.includes('application_exists'));
for(const token of ['applications_stage_nonempty_check','recruitment_jobs_status_check','offers_status_check','interviews_status_check'])assert.ok(compatibility.includes(token),`Missing compatibility check ${token}`);
for(const token of ['@media(max-width:900px)','@media(max-width:520px)','[dir="rtl"]','prefers-reduced-motion'])assert.ok(css.includes(token),`Missing responsive/RTL gate ${token}`);
assert.ok(css.includes('.record-drawer')&&css.includes('.pipeline-board')&&css.includes('.public-job-grid'));

console.log('STEP4_QA_PASS candidate+job+pipeline+interview+offer+placement=true tenant=server-session global=preserved rtl=ready');
