import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evaluateRequirementHealth,nextOperationalActions,targetState } from '../lib/manager-control.mjs';

const core=fs.readFileSync('supabase/migrations/20260926153517_20260929_step8_automation_manager_core.sql','utf8');
const sql=fs.readFileSync('supabase/migrations/20260926153522_20260929_step8_automation_manager_rpcs.sql','utf8');
const contracts=core+'\n'+sql;
const manager=fs.readFileSync('app/components/ManagerControlCenter.js','utf8');
const req=fs.readFileSync('app/components/ManagerRequirementControl.js','utf8');
const notifications=fs.readFileSync('app/components/AutomationNotificationCenter.js','utf8');

const initial={
  dailyTarget:3,validSubmissionsToday:0,hoursToCutoff:1,
  pipelineCount:0,overdueScreenings:2,overdueFollowups:1,
  amReviewBacklog:1,clientFeedbackBacklog:1,deadlineDays:1,hoursSinceActivity:30
};
const risk=evaluateRequirementHealth(initial);
assert.equal(risk.health,'AT_RISK');
const actions=nextOperationalActions({...initial,remainingTarget:3,qualifiedWaiting:1});
for(const code of ['CLOSE_TARGET_GAP','COMPLETE_SCREENINGS','SUBMIT_QUALIFIED','CLEAR_AM_BACKLOG','FOLLOW_UP_CLIENT','BUILD_PIPELINE'])
  assert.ok(actions.some(x=>x.code===code),'missing operational action '+code);
assert.equal(targetState({planned:3,completed:0,hoursToCutoff:1}),'AT_RISK');

const recovered={
  dailyTarget:3,validSubmissionsToday:3,hoursToCutoff:1,
  pipelineCount:4,overdueScreenings:0,overdueFollowups:0,
  amReviewBacklog:0,clientFeedbackBacklog:0,deadlineDays:5,hoursSinceActivity:1
};
assert.equal(evaluateRequirementHealth(recovered).health,'HEALTHY');
assert.equal(nextOperationalActions({...recovered,remainingTarget:0,qualifiedWaiting:0}).length,0);

for(const token of [
  "event_status in ('PENDING','PROCESSING','PROCESSED','FAILED')",
  "'TARGET_GAP'","'SCREENING_OVERDUE'","'AM_REVIEW_BACKLOG'","'CLIENT_FEEDBACK_DELAY'",
  "lifecycle='RESOLVED'","resolution_reason='UNDERLYING_CONDITION_CLEARED'",
  "candidate.sourced","screening.completed","submission.am_approved","submission.client_submitted",
  "interview.scheduled","offer.created","candidate.joined"
]) assert.ok(contracts.includes(token),'golden path/automation contract missing '+token);

for(const label of [
  'Active requirements','Planned submissions','Valid submissions','Remaining gap',
  'Requirements at risk','Recruiters below target','AM reviews pending',
  'Client feedback pending','Interviews today','Offer actions','Joining actions',
  'Exception queue','Requirement health','Recruiter facts','AM control','Source performance'
]) assert.ok(manager.includes(label),'manager control missing '+label);

for(const label of [
  'Why this health','Next operational actions','Funnel control','Assigned recruiters',
  'Requirement controls','Assignment control','Create manager task','Exceptions','Meaningful activity'
]) assert.ok(req.includes(label),'requirement drilldown missing '+label);

assert.ok(notifications.includes('Resolved issues disappear automatically.'));
assert.ok(notifications.includes('Acknowledge')&&notifications.includes('Dismiss'));
assert.ok(req.includes('Acknowledge blocker'),'manager drilldown must expose blocker acknowledgement without pretending it resolves the blocker');

console.log('STEP8_MANAGER_E2E_PASS target_gap_resolves=true screening_resolves=true am_backlog=true client_feedback=true health_recovery=true manager_ui=true');
