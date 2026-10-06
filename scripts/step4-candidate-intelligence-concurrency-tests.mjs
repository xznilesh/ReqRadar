import assert from 'node:assert/strict';
import fs from 'node:fs';
import { candidateMatchIdempotencyKey,candidateProfileHash } from '../lib/candidate-intelligence.mjs';
import { createCandidateInputHash } from '../lib/candidate-ai.mjs';
import { loadFixtures,profileForFixture } from './step4-candidate-intelligence-test-helpers.mjs';

const core=fs.readFileSync('supabase/migrations/20260926152601_20260927_step4_candidate_intelligence_core.sql','utf8');
const a=fs.readFileSync('supabase/migrations/20260926152606_20260927_step4_candidate_intelligence_rpcs_a.sql','utf8');
const b=fs.readFileSync('supabase/migrations/20260926153440_20260927_step4_candidate_intelligence_rpcs_b.sql','utf8');
const stale=fs.readFileSync('supabase/migrations/20260926153444_20260927_step4_candidate_intelligence_stale_guards.sql','utf8');
const step3=fs.readFileSync('supabase/migrations/20260926152551_20260926_step3_recruiter_execution_workspace.sql','utf8');

assert.ok(core.includes('unique(agency_id,idempotency_key)'),'match jobs need unique idempotency keys');
assert.ok(core.includes('unique(agency_id,candidate_id,version_number)'),'candidate profile versions must be unique');
assert.ok(core.includes('uq_xzr_candidate_profile_current'),'one current candidate profile must be enforced');
assert.ok(core.includes('unique(agency_id,intelligence_job_id)'),'one match result per intelligence job required');

assert.ok(a.includes('pg_advisory_xact_lock'),'concurrent repeated match-generation must serialize');
assert.ok(a.includes("v_existing.run_status='SUCCEEDED'")&&a.includes("'reused',true"),'successful replay must reuse result');
assert.ok(a.includes("v_existing.run_status='PROCESSING'")&&a.includes("interval '2 minutes'"),'active duplicate job must not fork');
assert.ok(a.includes('retry_count=retry_count+1'),'stale/failed processing retry accounting missing');

assert.ok(b.includes('for update'),'completion must lock the intelligence job');
assert.ok(b.includes('candidate_updated_at_snapshot'),'candidate change race guard missing');
assert.ok(b.includes('parse_run_updated_at_snapshot'),'resume parse race guard missing');
assert.ok(b.includes('brief_source_fingerprint'),'requirement-version race guard missing');
assert.ok(b.includes('stale_input_during_analysis'),'mixed-version completion must abort');
assert.ok(b.includes('candidate_intelligence_concurrent_conflict'),'unique race must fail retry-safe');
assert.ok(b.includes("run_status='STALE'")&&b.includes('current_candidate_match_id'),'historical match must be retained while pointer moves');

assert.ok(stale.includes('after update')&&stale.includes('xzr_candidate_intelligence_stale_on_profile'));
assert.ok(stale.includes('xzr_candidate_intelligence_stale_on_document'));
assert.ok(stale.includes('xzr_candidate_intelligence_stale_on_requirement'));
assert.ok(stale.includes('xzr_candidate_intelligence_stale_on_scoring'));
assert.ok(stale.includes("v_document_type='RESUME'"),'non-resume documents must not trigger candidate intelligence recompute');
assert.ok(stale.includes("tg_op='INSERT' and new.active=true"),'inactive scoring config insertion must not stale current matches');

assert.ok(step3.includes('checksum')&&step3.includes('candidate_documents'),'resume version/checksum contract required for double-upload protection');

const fixture=loadFixtures().find(x=>x.id==='strong_match');
const profile=profileForFixture(fixture);
const hash=candidateProfileHash(profile);
const base={agencyId:'tenant',jobId:'job-1',candidateId:'candidate',briefId:'brief-1',profileHash:hash,scoringVersion:'score-v2',promptVersion:'p1',schemaVersion:'m2'};
const same=candidateMatchIdempotencyKey(base);
assert.equal(same,candidateMatchIdempotencyKey({...base}));
assert.notEqual(same,candidateMatchIdempotencyKey({...base,jobId:'job-2'}),'same candidate across requirements must remain separate');
assert.notEqual(same,candidateMatchIdempotencyKey({...base,briefId:'brief-2'}),'requirement change must change idempotency identity');
assert.notEqual(same,candidateMatchIdempotencyKey({...base,profileHash:'updated-profile'}),'candidate/resume update must change idempotency identity');
assert.notEqual(same,candidateMatchIdempotencyKey({...base,scoringVersion:'score-v3'}),'scoring version change must change idempotency identity');

const rawHashA=createCandidateInputHash({resumeText:'same resume',candidateProfile:{id:'c'},requirementContext:{briefId:'b'},sourceMeta:{documentId:'doc1',documentVersion:1,parseRunId:'p1'}});
const rawHashB=createCandidateInputHash({resumeText:'same resume',candidateProfile:{id:'c'},requirementContext:{briefId:'b'},sourceMeta:{documentId:'doc2',documentVersion:2,parseRunId:'p2'}});
assert.notEqual(rawHashA,rawHashB,'new resume/document version must not reuse old intelligence even when extracted text is identical');

console.log('STEP4_CANDIDATE_CONCURRENCY_PASS advisory_lock=true replay=true stale_snapshots=true history=true resume_version=true multi_requirement=true');
