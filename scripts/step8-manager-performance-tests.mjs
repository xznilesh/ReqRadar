import assert from 'node:assert/strict';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
import { evaluateRequirementHealth,funnelCounts,sourceConversion } from '../lib/manager-control.mjs';

const core=fs.readFileSync('supabase/migrations/20260926153517_20260929_step8_automation_manager_core.sql','utf8');
const sql=fs.readFileSync('supabase/migrations/20260926153522_20260929_step8_automation_manager_rpcs.sql','utf8');

for(const idx of [
  'idx_xzr_step8_assignments_active','idx_xzr_step8_job_targets','idx_xzr_step8_app_stage_age',
  'idx_xzr_step8_tasks_due','idx_xzr_step8_submissions_control','idx_xzr_step8_interviews_control',
  'idx_xzr_step8_offers_control','idx_xzr_step8_placements_control','idx_xzr_step8_activity_control',
  'idx_xzr_step8_alert_queue','idx_xzr_step8_alert_owner','idx_xzr_step8_domain_events_pending'
]) assert.ok(core.includes(idx),'performance index missing '+idx);

for(const bound of [
  'limit 500','limit 300','limit 100','least(coalesce(p_limit,50),100)',
  'least(coalesce(p_tenant_limit,25),100)'
]) assert.ok(sql.includes(bound),'bounded query/worker contract missing '+bound);

const rows=Array.from({length:10000},(_,i)=>({
  source:['LINKEDIN','NAUKRI','REFERRAL','INTERNAL_DATABASE'][i%4],
  stage:['SOURCED','SCREENING_COMPLETED','QUALIFIED','CLIENT_SUBMITTED','INTERVIEW','OFFER','JOINED'][i%7],
  sourced:true,
  screened:i%7>=1,qualified:i%7>=2,internallySubmitted:i%7>=3,amApproved:i%7>=3,
  clientSubmitted:i%7>=3,interviewed:i%7>=4,offered:i%7>=5,joined:i%7>=6
}));
const start=performance.now();
const funnel=funnelCounts(rows);
const sources=sourceConversion(rows);
for(let i=0;i<1000;i++)evaluateRequirementHealth({
  dailyTarget:3,validSubmissionsToday:i%4,hoursToCutoff:i%8,pipelineCount:i%5,
  overdueScreenings:i%3,overdueFollowups:i%2,deadlineDays:i%10,hoursSinceActivity:i%48
});
const elapsed=performance.now()-start;
assert.equal(funnel.sourced,10000);
assert.equal(sources.length,4);
assert.ok(elapsed<1500,'10k analytics + 1k health rules should remain comfortably bounded in CI');

console.log('STEP8_MANAGER_PERFORMANCE_PASS synthetic_candidates=10000 health_evals=1000 elapsed_ms='+elapsed.toFixed(2)+' indexes=true bounded_queries=true');
