import assert from 'node:assert/strict';
import fs from 'node:fs';
import { ROLE_PERMISSIONS } from '../lib/security-policy.mjs';

const sql=fs.readFileSync('supabase/migrations/20260926153512_20260928_step7_enterprise_multitenant_security_foundation.sql','utf8');

for(const token of [
  'u.disabled_at is null','am.active=true','s.revoked_at is null','s.expires_at>now()',
  'xzrecruiter_membership_session_guard','xzrecruiter_disabled_user_session_guard',
  'membership.role_changed','membership.removed','sessions_revoked',
  'workspace_invitations_business_role_step7_check','membership.invite_created',
  'private.xzrecruiter_has_permission','private.xzrecruiter_candidate_object_access',
  'private.xzrecruiter_job_object_access','private.xzrecruiter_attachment_object_access',
  'private.xzrecruiter_entity_belongs_to_agency'
])assert.ok(sql.includes(token),'missing auth/object security contract: '+token);

assert.ok(sql.includes("j.recruiter_ready=true")&&sql.includes("j.requirement_state='OPEN'"),
  'recruiter object access must collapse when requirement leaves approved recruiter-ready state');

for(const [role,permissions] of Object.entries(ROLE_PERMISSIONS)){
  if(permissions.includes('*'))continue;
  for(const permission of permissions){
    if(role==='CLIENT_USER')continue;
    assert.ok(sql.includes("'"+permission+"'"),'DB capability map missing JS permission '+role+':'+permission);
  }
}
assert.ok(!/workspace_invitations_business_role_step7_check[\s\S]{0,500}'OWNER'/.test(sql),
  'OWNER must never be assignable through invitation role constraint');

for(const token of [
  "where table_schema='public' and column_name='agency_id'",
  "alter table public.%I enable row level security",
  "create policy xzrecruiter_data_api_deny",
  "using (false) with check (false)",
  "'users','user_credentials','user_sessions','auth_login_events','password_reset_tokens'",
  "alter view %I.%I set (security_invoker=true)",
  "p.prosecdef=true","revoke execute on function %s from public"
])assert.ok(sql.includes(token),'RLS/privileged database boundary missing: '+token);

for(const pair of [
  ['candidate_documents','HIGHLY_SENSITIVE'],
  ['application_screening_sessions','HIGHLY_SENSITIVE'],
  ['application_screening_answers','HIGHLY_SENSITIVE'],
  ['candidate_fact_assertions','HIGHLY_SENSITIVE'],
  ['candidate_submissions','CONFIDENTIAL'],
  ['candidate_submission_versions','CONFIDENTIAL'],
  ['requirement_hiring_briefs','INTERNAL']
]){
  assert.ok(sql.includes('alter table public.'+pair[0]),'classification column missing '+pair[0]);
  assert.ok(sql.includes("default '"+pair[1]+"'"),'classification default missing '+pair[0]);
}

for(const token of [
  'public.security_events','public.organization_data_governance','public.security_rate_limits',
  'xzrecruiter_log_security_event','document.access_denied','attachment.access_denied',
  'candidate.export_denied','submission.am_review_denied','submission.client_submit_denied',
  'commercial.read_denied','commercial.write_denied'
])assert.ok(sql.includes(token),'security audit event contract missing '+token);

assert.ok(sql.includes('grant execute on function public.xzrecruiter_consume_rate_limit')&&sql.includes('to service_role'),
  'durable rate-limit mutation must be service-role only');
assert.ok(!/grant execute on function public\.xzrecruiter_consume_rate_limit[\s\S]{0,100}to (anon|authenticated)/i.test(sql),
  'rate-limit primitive must not be browser callable');

for(const token of [
  'xzrecruiter_candidate_document_access_step7_legacy','document:resume_view','document:sensitive_view',
  'xzrecruiter_attachment_access_step7_legacy','xzrecruiter_attachment_gate',
  'xzrecruiter_candidate_export_step7_legacy','bulk_export_forbidden',
  'xzrecruiter_crm_dispatch','commercial:view','commercial:edit'
])assert.ok(sql.includes(token),'wrapper/revocation security boundary missing '+token);

assert.ok((sql.match(/pg_advisory_xact_lock/g)||[]).length>=3,'critical submission operations need transaction locks');
assert.ok(sql.includes('idx_xzr_candidates_tenant_owner_active'));
assert.ok(sql.includes('idx_xzr_applications_tenant_candidate_job'));
assert.ok(sql.includes('idx_xzr_assignments_tenant_recruiter_job'));
assert.ok(sql.includes('idx_xzr_documents_tenant_candidate_active'));
assert.ok(sql.includes('idx_xzr_submissions_tenant_state'));
assert.ok(sql.includes('idx_xzr_tasks_tenant_due'));

assert.ok(sql.includes('revoke update,delete on public.audit_events,public.security_events from anon,authenticated'),
  'ordinary users must not mutate/delete audit/security events');
assert.ok(!/\bdrop\s+table\b|\btruncate\b|alter\s+table\s+[^;]+\s+drop\s+column/i.test(sql),
  'Step-7 security migration must be non-destructive');

console.log('STEP7_SECURITY_INTEGRATION_PASS session_revocation=true rls=true capabilities=true object_auth=true documents=true audit=true locks=true indexes=true');
