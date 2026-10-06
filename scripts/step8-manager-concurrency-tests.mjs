import assert from 'node:assert/strict';
import fs from 'node:fs';

const core=fs.readFileSync('supabase/migrations/20260926153517_20260929_step8_automation_manager_core.sql','utf8');
const sql=fs.readFileSync('supabase/migrations/20260926153522_20260929_step8_automation_manager_rpcs.sql','utf8');
const ui=fs.readFileSync('app/components/ManagerRequirementControl.js','utf8');

assert.ok(core.includes('unique(agency_id,dedupe_key)'),'alert duplicate prevention missing');
assert.ok(core.includes('unique(source_activity_event_id)'),'domain event replay prevention missing');
assert.ok(core.includes('uq_xzr_crm_task_automation'),'automation task duplicate prevention missing');
assert.ok(sql.includes('for update;'),'alert/task mutation row locking missing');
assert.ok(sql.includes("pg_advisory_xact_lock(hashtext('xzr-step8-'||p_agency::text))"),'full tenant automation lock missing');
assert.ok(sql.includes("pg_try_advisory_xact_lock(hashtext('xzr-step8-event-'||v_row.agency_id::text))"),'event-worker tenant lock missing');
assert.ok(core.includes('on conflict(source_activity_event_id) do nothing'),'event outbox replay must be idempotent');
assert.ok(sql.includes('on conflict(agency_id,automation_key)'),'manager/automation task retry must be idempotent');
assert.ok(core.includes('unique(agency_id,dedupe_key)')&&sql.includes("pg_advisory_xact_lock(hashtext('xzr-step8-'||p_agency::text))"),'alert retry must preserve one canonical alert under tenant serialization');
assert.ok(sql.includes('last_detected_run_id is distinct from v_run')&&sql.includes('step8_alert_condition_holds'),'bounded scan must not resolve unseen-but-still-active issue');
assert.ok(sql.includes("event_status=case when attempt_count>=5 then 'FAILED' else 'PENDING' end"),'event retry ceiling missing');
assert.ok(sql.includes("'xzrecruiter-step8-events'")&&sql.includes("'xzrecruiter-step8-full-reconcile'"),'scheduled catch-up/reconciliation missing');
assert.ok(ui.includes('const idempotencyRef=useRef(uid())')&&ui.includes('idempotencyRef.current=uid()'),'new manager task must rotate idempotency key after success');

const keyExpr="lower(coalesce(p_rule,''))||'|'||lower(coalesce(p_entity_type,''))||'|'||coalesce(p_entity_id::text,'')||'|'||coalesce(p_owner::text,'')";
assert.ok(sql.includes(keyExpr),'deterministic alert key must include rule/entity/owner');

console.log('STEP8_MANAGER_CONCURRENCY_PASS alerts=true tasks=true events=true tenant_locks=true retry=true bounded_resolution=true');
