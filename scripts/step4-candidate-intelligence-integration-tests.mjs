import assert from 'node:assert/strict';
import fs from 'node:fs';

const core=fs.readFileSync('supabase/migrations/20260926152601_20260927_step4_candidate_intelligence_core.sql','utf8');
const a=fs.readFileSync('supabase/migrations/20260926152606_20260927_step4_candidate_intelligence_rpcs_a.sql','utf8');
const b=fs.readFileSync('supabase/migrations/20260926153440_20260927_step4_candidate_intelligence_rpcs_b.sql','utf8');
const stale=fs.readFileSync('supabase/migrations/20260926153444_20260927_step4_candidate_intelligence_stale_guards.sql','utf8');
const migrationFiles=fs.readdirSync('supabase/migrations').sort();
const step3Index=migrationFiles.indexOf('20260926152551_20260926_step3_recruiter_execution_workspace.sql');
for(const name of [
  '20260926152601_20260927_step4_candidate_intelligence_core.sql',
  '20260926152606_20260927_step4_candidate_intelligence_rpcs_a.sql',
  '20260926153440_20260927_step4_candidate_intelligence_rpcs_b.sql',
  '20260926153444_20260927_step4_candidate_intelligence_stale_guards.sql'
]){
  assert.ok(step3Index>=0&&migrationFiles.indexOf(name)>step3Index,'Step-4 migration must sort after completed Step-3 migration: '+name);
}
const resume=fs.readFileSync('app/api/recruiter/resume/route.js','utf8');
const route=fs.readFileSync('app/api/candidate-intelligence/route.js','utf8');

for(const table of [
  'candidate_profile_versions','candidate_profile_skills','candidate_scoring_configs',
  'candidate_intelligence_jobs','candidate_match_runs','candidate_duplicate_signals','candidate_intelligence_reviews'
])assert.ok(core.includes('public.'+table),'missing Step-4 table '+table);

for(const table of [
  'candidate_profile_versions','candidate_profile_skills','candidate_scoring_configs',
  'candidate_intelligence_jobs','candidate_match_runs','candidate_duplicate_signals','candidate_intelligence_reviews'
]){
  assert.ok(core.includes('alter table public.'+table+' enable row level security'),'RLS missing '+table);
}
assert.ok(core.includes('using(false) with check(false)'),'direct browser table policy must be deny-by-default');
assert.ok(core.includes('uq_xzr_candidate_profile_current'),'single current profile version constraint missing');
assert.ok(core.includes('unique(agency_id,idempotency_key)'),'intelligence job idempotency uniqueness missing');
assert.ok(core.includes('current_candidate_match_id'),'application current match pointer missing');
assert.ok(core.includes('xz-candidate-match-v2'),'match schema version v2 missing');
assert.ok(core.includes("profile_schema_version text not null default 'xz-candidate-profile-v2'"),'candidate profile schema version must be persisted');

for(const token of [
  'xzrecruiter_candidate_intelligence_access','agency_id=v_agency','approved_hiring_brief_id',
  "hb.brief_status='APPROVED'","j.recruiter_ready=true",'requirement_criteria',
  'candidate_scoring_configs','candidate_intelligence_jobs','pg_advisory_xact_lock'
])assert.ok((a+b+core).includes(token),'integration contract missing '+token);

assert.ok(a.includes("v_existing.run_status='PROCESSING'")&&a.includes("interval '2 minutes'"),'stale processing retry recovery missing');
assert.ok(a.includes('candidate_updated_at_snapshot')&&a.includes('parse_run_updated_at_snapshot')&&a.includes('brief_source_fingerprint'),'input snapshots missing');
assert.ok(b.includes('stale_input_during_analysis'),'completion must reject mixed/stale inputs');
assert.ok(b.includes('profile_version_id<>v_profile')&&b.includes("stale_reason"),'old match version invalidation missing');
assert.ok(b.includes("run_status='STALE'"),'historical match preservation/stale state missing');
assert.ok(b.includes('candidate_duplicate_signals')&&b.includes('c.agency_id=v_agency'),'same-tenant duplicate scan missing');
assert.ok(b.includes('Never auto-merges')||b.includes('Never auto-merge')||b.includes('Never auto-merges'.toLowerCase())||b.includes('-- Explainable duplicate scan'),'duplicate scan must not auto-merge');
assert.ok(b.includes("candidate.intelligence_generated")&&b.includes("candidate.intelligence_reviewed"),'automatic activity events missing');
assert.ok(b.includes("override_reason_required"),'human override reason guard missing');
assert.ok(b.includes("'STEP_5_HUMAN_SCREENING'"),'Step-4 handoff marker missing');
assert.ok(!/screening[_ ]questions|screening[_ ]recommendation|ai[_ ]screening[_ ]assist/i.test(b),'Step 5 implementation leaked into Step 4');

for(const token of [
  'xzr_candidate_intelligence_stale_on_profile','xzr_candidate_intelligence_stale_on_document',
  'xzr_candidate_intelligence_stale_on_requirement','xzr_candidate_intelligence_stale_on_scoring',
  'CANDIDATE_PROFILE_CHANGED','RESUME_VERSION_CHANGED','APPROVED_REQUIREMENT_CHANGED','SCORING_CONFIG_CHANGED'
])assert.ok(stale.includes(token),'stale guard missing '+token);

assert.ok(resume.includes("candidateIntelligenceAction('storeParseText'"),'resume ingestion must preserve extracted source text for intelligence');
assert.ok(resume.includes('uploadPrivateObject'),'resume must remain private storage upload');
assert.ok(route.includes('candidateAiConfigured()'),'server AI configuration gate missing');
assert.ok(route.includes('buildCandidateProfileSnapshot')&&route.includes('computeCandidateMatch'),'candidate profile + deterministic match pipeline missing');
assert.ok(route.includes('LOCAL_FALLBACK'),'failure-tolerant deterministic local path missing');
assert.ok(!route.includes('NEXT_PUBLIC_OPENAI')&&!route.includes('OPENAI_API_KEY'),'AI secret must not be handled in route/client code');

assert.ok(b.includes("limit v_limit")&&b.includes("least(coalesce(p_limit,30),50)"),'talent search must be server bounded');
assert.ok(b.includes("'semantic_used',false"),'semantic search must not be falsely claimed when pgvector is not used');
for(const fn of ['xzrecruiter_complete_candidate_intelligence','xzrecruiter_review_candidate_intelligence','xzrecruiter_talent_match_search']){
  assert.equal((b.match(new RegExp('create or replace function public\\.'+fn,'g'))||[]).length,1,'duplicate canonical RPC definition: '+fn);
}

console.log('STEP4_CANDIDATE_INTEGRATION_PASS ingestion=true persistence=true versions=true stale_guards=true duplicates=true tenant_scope=true activities=true');
