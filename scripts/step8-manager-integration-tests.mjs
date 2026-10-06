import assert from 'node:assert/strict';
import fs from 'node:fs';

const core=fs.readFileSync('supabase/migrations/20260926153517_20260929_step8_automation_manager_core.sql','utf8');
const rpcs=fs.readFileSync('supabase/migrations/20260926153522_20260929_step8_automation_manager_rpcs.sql','utf8');
const api=fs.readFileSync('app/api/manager-control/route.js','utf8');
const cronApi=fs.readFileSync('app/api/automation/run/route.js','utf8');
const managerUi=fs.readFileSync('app/components/ManagerControlCenter.js','utf8');
const reqUi=fs.readFileSync('app/components/ManagerRequirementControl.js','utf8');
const notifUi=fs.readFileSync('app/components/AutomationNotificationCenter.js','utf8');

for(const table of [
  'automation_control_configs','requirement_health_current','automation_runs',
  'automation_alerts','automation_domain_events','automation_alert_events'
]) {
  assert.ok(core.includes('create table if not exists public.'+table),'missing '+table);
  assert.ok(core.includes('alter table public.'+table+' enable row level security'),'RLS missing '+table);
}
assert.ok(core.includes('using(false) with check(false)'),'Step-8 direct Data API policy must deny browser table access');
assert.ok(core.includes('unique(agency_id,dedupe_key)'),'alert tenant-aware dedupe key missing');
assert.ok(core.includes('unique(source_activity_event_id)'),'domain-event outbox idempotency missing');
assert.ok(core.includes('uq_xzr_crm_task_automation'),'automation task uniqueness missing');
assert.ok(core.includes('immutable_step8_alert_event'),'alert history immutability missing');
assert.ok(core.includes('xzr_step8_activity_event_outbox'),'domain-event activity outbox trigger missing');
assert.ok(core.includes('create extension if not exists pg_cron'),'pg_cron scheduler foundation missing');

const rmBlock=core.match(/when 'RECRUITMENT_MANAGER' then[\s\S]*?\]\)/)?.[0]||'';
const amBlock=core.match(/when 'ACCOUNT_MANAGER' then[\s\S]*?\]\)/)?.[0]||'';
assert.ok(rmBlock.includes("'manager:view'")&&rmBlock.includes("'manager:control'"),'Recruitment Manager manager capabilities missing');
assert.ok(!amBlock.includes("'manager:view'")&&!amBlock.includes("'manager:control'"),'Account Manager must not inherit manager-wide privileges');
assert.ok(amBlock.includes("'automation:ack'"),'Account Manager should still receive/ack authorized operational alerts');

for(const fn of [
  'private.xzrecruiter_step8_upsert_alert',
  'private.xzrecruiter_step8_ensure_task',
  'private.xzrecruiter_step8_alert_condition_holds',
  'private.xzrecruiter_step8_run_agency',
  'public.xzrecruiter_run_step8_all_tenants',
  'public.xzrecruiter_run_step8_pending_events',
  'public.xzrecruiter_run_step8_manual',
  'public.xzrecruiter_step8_notification_center',
  'public.xzrecruiter_step8_alert_action',
  'public.xzrecruiter_step8_manager_control_center',
  'public.xzrecruiter_step8_requirement_control',
  'public.xzrecruiter_step8_analytics',
  'public.xzrecruiter_step8_manager_action',
  'public.xzrecruiter_step8_record_client_feedback'
]) assert.ok(rpcs.includes('create or replace function '+fn),'missing function '+fn);

assert.ok(rpcs.includes('as $alert$')&&rpcs.includes('$alert$;'),'alert condition SQL delimiter broken');
assert.ok(rpcs.includes('as $events$')&&rpcs.includes('$events$;'),'pending-event SQL delimiter broken');

for(const token of [
  "j.recruiter_ready=true","j.requirement_state='OPEN'","j.approved_hiring_brief_id is not null",
  "workflow_status='CLIENT_SUBMITTED'","invalidated_at is null","withdrawn_at is null",
  "upper(coalesce(ap.stage,'')) not in ('WITHDRAWN','REJECTED')",
  'private.xzrecruiter_step8_alert_condition_holds(p_agency,a.id)'
]) assert.ok(rpcs.includes(token),'canonical active/valid control contract missing '+token);

assert.ok(rpcs.includes("pg_advisory_xact_lock(hashtext('xzr-step8-'"),'tenant automation concurrency lock missing');
assert.ok(rpcs.includes("pg_try_advisory_xact_lock(hashtext('xzr-step8-event-'"),'event worker concurrency lock missing');
assert.ok(rpcs.includes("event_status=case when attempt_count>=5 then 'FAILED' else 'PENDING' end"),'event retry/dead-letter state missing');
assert.ok(rpcs.includes("last_detected_run_id is distinct from v_run")&&rpcs.includes('alert_condition_holds'),'bounded scans must not falsely resolve still-applicable alerts');

for(const rule of [
  'REQUIREMENT_HEALTH','RECRUITER_TARGET_GAP','PIPELINE_STAGNATION','SCREENING_ACTION_OVERDUE',
  'FOLLOW_UP_OVERDUE','AM_REVIEW_OVERDUE','CLIENT_FEEDBACK_OVERDUE','INTERVIEW_UPCOMING',
  'DOCUMENT_EXPIRY','OFFER_ACTION_OVERDUE','JOINING_ACTION'
]) assert.ok(rpcs.includes("'"+rule+"'"),'automation rule missing '+rule);

assert.ok(rpcs.includes("'xzrecruiter-step8-events'")&&rpcs.includes("'* * * * *'"),'event scheduler must run every minute');
assert.ok(rpcs.includes("'xzrecruiter-step8-full-reconcile'")&&rpcs.includes("'0 * * * *'"),'hourly full reconciliation schedule missing');
assert.ok(rpcs.includes("grant execute on function public.xzrecruiter_run_step8_all_tenants(text) to service_role"),'all-tenant runner must be service-role only');
assert.ok(rpcs.includes("grant execute on function public.xzrecruiter_run_step8_pending_events(text,integer) to service_role"),'pending-event runner must be service-role only');

assert.ok(rpcs.includes("if v_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER')"),'client feedback must preserve AM ownership boundary');
assert.ok(rpcs.includes("'requirement_not_operational'")&&rpcs.includes("'invalid_requirement_transition'"),'manager mutations need canonical state guards');
assert.ok(rpcs.includes("'manager.action_denied'"),'manager authorization denial security event missing');
assert.ok(rpcs.includes("'blocker_not_found'")&&rpcs.includes("'blocker_preserved',true"),'blocker acknowledgement must preserve underlying blocker state');
assert.ok(!/ACKNOWLEDGE_BLOCKER'[\s\S]{0,700}blocker_reason=null/.test(rpcs),'acknowledgement must not clear blocker_reason');

assert.ok(api.includes('mutationRequestIsTrusted(req)')&&api.includes('declaredBodyWithin(req,MAX_BODY)'),'manager mutation request integrity missing');
assert.ok(cronApi.includes('CRON_SECRET')&&cronApi.includes('serviceRpc'),'secured automation runner missing');
assert.ok(managerUi.includes('setInterval(()=>refresh({silent:true}),30000)'),'manager near-real-time refresh missing');
assert.ok(reqUi.includes('useRef(uid())')&&reqUi.includes('idempotencyRef.current=uid()'),'manager task idempotency key rotation missing');
assert.ok(!notifUi.includes("RECRUITMENT_MANAGER','ACCOUNT_MANAGER'].includes(String(data.role"),'AM must not be linked into manager-only routes');

assert.ok(!/Step 9|pilot validation|launch readiness/i.test(core+rpcs),'Step-9 scope leaked into Step 8');

console.log('STEP8_MANAGER_INTEGRATION_PASS rls=true rbac=true scheduler=true active_scope=true lifecycle=true idempotency=true boundaries=true');
