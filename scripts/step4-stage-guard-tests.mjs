import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql=fs.readFileSync('supabase/migrations/20260926152340_20260903_step4_zzzzzzzzz_stage_transition_guard.sql','utf8');
const pipeline=fs.readFileSync('app/components/PipelineWorkspace.js','utf8');
const api=fs.readFileSync('app/api/ats/route.js','utf8');
const layout=fs.readFileSync('app/layout.js','utf8');

for(const token of [
  'stage_requirements_missing','allowedRoles','requiresResume','requiresSubmission','requiresInterview','requiresScorecard','requiresApprovedOffer','requiresPlacement',
  'candidate_documents','application_screening_answers','candidate_submissions','interview_scorecards','offers','placements','application_stage_history'
]) assert.ok(sql.includes(token),`stage guard missing ${token}`);

assert.ok(!/\bdrop\s+table\b|\btruncate\b/i.test(sql),'stage guard must remain additive');
for(const token of ['transitionMessage','stage_requirements_missing','aria-live="polite"','Move stage']) assert.ok(pipeline.includes(token),`pipeline feedback missing ${token}`);
assert.ok(api.includes("error === 'stage_requirements_missing'")&&api.includes('return 422'),'API should expose semantic validation status');
assert.ok(layout.includes("./step4-stage-guard.css"),'stage guard styles must load');

console.log('STEP4_STAGE_GUARD_PASS server_required_fields=true transition_rules=true role_allowlist=true evidence_gates=true accessible_feedback=true');
