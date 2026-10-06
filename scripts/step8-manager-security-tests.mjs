import assert from 'node:assert/strict';
import fs from 'node:fs';

const core=fs.readFileSync('supabase/migrations/20260926153517_20260929_step8_automation_manager_core.sql','utf8');
const sql=fs.readFileSync('supabase/migrations/20260926153522_20260929_step8_automation_manager_rpcs.sql','utf8');
const managerApi=fs.readFileSync('app/api/manager-control/route.js','utf8');
const cronApi=fs.readFileSync('app/api/automation/run/route.js','utf8');
const server=fs.readFileSync('lib/manager-control-server.js','utf8');
const client=fs.readFileSync('app/components/ManagerControlCenter.js','utf8')+
  fs.readFileSync('app/components/ManagerRequirementControl.js','utf8');

assert.ok((core.match(/enable row level security/g)||[]).length>=6,'all Step-8 tenant tables must enable RLS');
assert.ok(core.includes("create policy xzrecruiter_data_api_deny"),'deny-by-default Step-8 Data API policy missing');

for(const fn of [
  'xzrecruiter_run_step8_all_tenants(text)',
  'xzrecruiter_run_step8_pending_events(text,integer)'
]) {
  assert.ok(sql.includes('revoke all on function public.'+fn+' from public,anon,authenticated'),'privileged worker revoke missing '+fn);
  assert.ok(sql.includes('grant execute on function public.'+fn+' to service_role'),'privileged worker service_role grant missing '+fn);
}

assert.ok(sql.includes('private.xzrecruiter_session_context(p_token)'),'manager/session identity must derive server-side');
assert.ok(sql.includes("private.xzrecruiter_has_permission(v_role,'manager:view')"),'manager view capability guard missing');
assert.ok(sql.includes("private.xzrecruiter_has_permission(v_role,'manager:control')"),'manager mutation capability guard missing');
assert.ok(sql.includes("'manager.action_denied','HIGH'"),'manager denial security event missing');
assert.ok(sql.includes("'automation.alert_access_denied','HIGH'"),'alert IDOR denial event missing');

const amBlock=core.match(/when 'ACCOUNT_MANAGER' then[\s\S]*?\]\)/)?.[0]||'';
const recruiterBlock=core.match(/when 'RECRUITER' then[\s\S]*?\]\)/)?.[0]||'';
assert.ok(!amBlock.includes("'manager:view'")&&!amBlock.includes("'manager:control'"),'AM privilege escalation into manager control');
assert.ok(!recruiterBlock.includes("'manager:view'")&&!recruiterBlock.includes("'manager:control'"),'Recruiter privilege escalation into manager control');
assert.ok(sql.includes("if v_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER')"),'client feedback must not be writable by recruitment manager');

for(const token of [
  'where a.agency_id=p_agency','where a.agency_id=v_agency',
  'where j.agency_id=p_agency','where j.agency_id=v_agency',
  'where s.agency_id=p_agency','where s.agency_id=v_agency'
]) assert.ok(sql.includes(token),'tenant scoping pattern missing '+token);

assert.ok(managerApi.includes('mutationRequestIsTrusted(req)'),'manager POST CSRF/request-integrity guard missing');
assert.ok(managerApi.includes('declaredBodyWithin(req,MAX_BODY)'),'manager POST payload limit missing');
assert.ok(managerApi.includes("const allowed=new Set(['SET_PRIORITY','HOLD_REQUIREMENT','REOPEN_REQUIREMENT','ASSIGN_RECRUITER','SET_RECRUITER_TARGET','CREATE_MANAGER_TASK','ACKNOWLEDGE_BLOCKER'])"),'manager action allowlist missing');
assert.ok(cronApi.includes('CRON_SECRET')&&cronApi.includes("headers.get('authorization')"),'cron bearer-secret authorization missing');
assert.ok(server.includes("rpc('xzrecruiter_step8_manager_control_center'"),'server-only RPC adapter missing');
assert.ok(!client.includes('SUPABASE_SERVICE_ROLE_KEY')&&!client.includes('CRON_SECRET'),'privileged secrets leaked into client bundle');

assert.ok(sql.includes("'requirement_not_operational'")&&sql.includes("'invalid_requirement_transition'"),'forged manager state transition guard missing');
assert.ok(sql.includes("j.recruiter_ready=true")&&sql.includes("j.approved_hiring_brief_id is not null"),'manager automation must not control unapproved requirements');

console.log('STEP8_MANAGER_SECURITY_PASS cross_tenant=true rbac=true idor=true csrf=true privileged_runner=true state_guards=true secret_boundary=true');
