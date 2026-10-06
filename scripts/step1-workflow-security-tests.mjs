import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration=fs.readFileSync('supabase/migrations/20260926152509_20260925_step1_workflow_contract_lock.sql','utf8');
const ats=fs.readFileSync('lib/ats.js','utf8');
const drawer=fs.readFileSync('app/components/ApplicationScreeningDrawer.js','utf8');

const privileged=[
  'xzrecruiter_move_application_workflow(text,uuid,uuid,text)',
  'xzrecruiter_save_candidate_submission(text,uuid,jsonb,boolean)',
  'xzrecruiter_review_internal_submission(text,uuid,text,text)',
  'xzrecruiter_mark_client_submitted(text,uuid)',
  'xzrecruiter_application_closeout_context(text,uuid)',
  'xzrecruiter_schedule_interview(text,jsonb)',
  'xzrecruiter_save_offer(text,jsonb)',
  'xzrecruiter_offer_approval_action(text,uuid,text,text)',
  'xzrecruiter_offer_set_status(text,uuid,text)',
  'xzrecruiter_create_placement(text,jsonb)',
];
for(const signature of privileged){
  assert.ok(migration.includes(`revoke all on function public.${signature} from public,anon,authenticated`), `PUBLIC execute not revoked: ${signature}`);
  assert.ok(migration.includes(`grant execute on function public.${signature} to anon,authenticated`), `explicit API grant missing: ${signature}`);
}

for(const helper of [
  'private.xzrecruiter_business_role(uuid,uuid,text)',
  'private.xzrecruiter_canonical_candidacy_state(text)',
  'private.xzrecruiter_candidacy_transition_allowed(text,text,text)',
]) assert.ok(migration.includes(`revoke all on function ${helper} from public,anon,authenticated`), `private helper leaked: ${helper}`);

for(const token of [
  'from private.xzrecruiter_session_context(p_token)',
  'agency_id=v_agency',
  'cs.agency_id=v_agency',
  'a.agency_id=v_agency',
  'where id=p_offer_id and agency_id=v_agency',
  'where id=p_submission_id and agency_id=v_agency',
]) assert.ok(migration.includes(token), `tenant scoping invariant missing: ${token}`);

assert.ok(!ats.includes('p_agency_id'), 'browser/server wrapper must never accept caller-supplied tenant id');
assert.ok(ats.includes("moveApplication: ['xzrecruiter_move_application_workflow'"), 'unguarded stage RPC still exposed by app wrapper');
assert.ok(!drawer.includes('Submit to client'), 'recruiter client-release action still exposed');
assert.ok(migration.includes("v_business_role not in ('OWNER','ADMIN','ACCOUNT_MANAGER')"), 'AM-owned offer/client guard missing');
assert.ok(migration.includes("v_business_role not in ('OWNER','ADMIN','RECRUITMENT_MANAGER','RECRUITER')"), 'recruiter internal handoff role guard missing');
assert.ok(migration.includes("'am_quality_gate_required'"), 'AM quality gate bypass guard missing');
assert.ok(migration.includes("'accepted_offer_required'"), 'joining before accepted offer guard missing');
assert.ok(migration.includes("workflow_status='CLIENT_SUBMITTED'"), 'client-submitted evidence gate missing');
assert.ok(!/\bdrop\s+table\b|\btruncate\b|alter\s+table\s+[^;]+\s+drop\s+column/i.test(migration), 'destructive Step-1 SQL detected');

console.log('STEP1_WORKFLOW_SECURITY_PASS tenant_scope=true role_separation=true rpc_privileges=explicit legacy_bypass=revoked destructive=false');
