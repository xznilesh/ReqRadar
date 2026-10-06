import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  CanonicalFlow, Roles, Permission, hasPermission, canTransition, assertTransition,
  RequirementState, CandidacyState, ScreeningState, InternalSubmissionState,
  AmReviewState, ClientSubmissionState, InterviewState, OfferState, JoiningState,
  AiBoundaries, AuditEvents, MinimumDataContract, requiredAuditContext,
} from '../lib/workflow-contract.mjs';

const EXPECTED_FLOW = [
  'CLIENT_JD','AM_RECEIVES_REQUIREMENT','AI_HIRING_BRIEF','AM_CONFIRMS_CLIENT_INTENT',
  'RECRUITER_SOURCING','CANDIDATE_IN_XZ_RECRUITER','AI_CANDIDATE_ANALYSIS',
  'HUMAN_SCREENING','INTERNAL_SUBMISSION','AI_SUBMISSION_PACK','AM_QUALITY_GATE',
  'CLIENT_SUBMISSION','INTERVIEW','OFFER','JOINING','ANALYTICS_LEARNING_LOOP',
];
assert.deepEqual(CanonicalFlow, EXPECTED_FLOW, 'exactly one locked canonical flow must exist');

// Role separation: recruiter operates candidate execution; AM owns client/quality/commercial release.
assert.equal(hasPermission(Roles.RECRUITER, Permission.SCREEN_CANDIDATE), true);
assert.equal(hasPermission(Roles.RECRUITER, Permission.INTERNAL_SUBMIT), true);
assert.equal(hasPermission(Roles.RECRUITER, Permission.AM_QUALITY_GATE), false);
assert.equal(hasPermission(Roles.RECRUITER, Permission.CLIENT_SUBMIT), false);
assert.equal(hasPermission(Roles.ACCOUNT_MANAGER, Permission.APPROVE_HIRING_BRIEF), true);
assert.equal(hasPermission(Roles.ACCOUNT_MANAGER, Permission.AM_QUALITY_GATE), true);
assert.equal(hasPermission(Roles.ACCOUNT_MANAGER, Permission.CLIENT_SUBMIT), true);
assert.equal(hasPermission(Roles.ACCOUNT_MANAGER, Permission.SCREEN_CANDIDATE), false);
assert.equal(hasPermission(Roles.COMPLIANCE_REVIEWER, Permission.REVIEW_COMPLIANCE), true);
assert.equal(hasPermission(Roles.CLIENT, Permission.CLIENT_FEEDBACK), true);

// Requirement happy path.
assert.equal(canTransition('REQUIREMENT', RequirementState.JD_RECEIVED, RequirementState.AI_BRIEF_PENDING, Roles.ACCOUNT_MANAGER), true);
assert.equal(canTransition('REQUIREMENT', RequirementState.AI_BRIEF_PENDING, RequirementState.AM_REVIEW, Roles.AI), true);
assert.equal(canTransition('REQUIREMENT', RequirementState.AM_REVIEW, RequirementState.APPROVED, Roles.ACCOUNT_MANAGER), true);
assert.equal(canTransition('REQUIREMENT', RequirementState.APPROVED, RequirementState.OPEN, Roles.ACCOUNT_MANAGER), true);

// Candidate happy path: no client submission until AM has the record.
const candidacyHappyPath = [
  [CandidacyState.SOURCED, CandidacyState.AI_ANALYSIS_PENDING, Roles.RECRUITER],
  [CandidacyState.AI_ANALYSIS_PENDING, CandidacyState.READY_FOR_HUMAN_SCREEN, Roles.AI],
  [CandidacyState.READY_FOR_HUMAN_SCREEN, CandidacyState.SCREENING, Roles.RECRUITER],
  [CandidacyState.SCREENING, CandidacyState.QUALIFIED, Roles.RECRUITER],
  [CandidacyState.QUALIFIED, CandidacyState.INTERNAL_SUBMISSION, Roles.RECRUITER],
  [CandidacyState.INTERNAL_SUBMISSION, CandidacyState.AM_REVIEW, Roles.RECRUITER],
  [CandidacyState.AM_REVIEW, CandidacyState.CLIENT_SUBMITTED, Roles.ACCOUNT_MANAGER],
  [CandidacyState.CLIENT_SUBMITTED, CandidacyState.INTERVIEW, Roles.ACCOUNT_MANAGER],
  [CandidacyState.INTERVIEW, CandidacyState.OFFER, Roles.ACCOUNT_MANAGER],
  [CandidacyState.OFFER, CandidacyState.JOINING, Roles.ACCOUNT_MANAGER],
  [CandidacyState.JOINING, CandidacyState.JOINED, Roles.ACCOUNT_MANAGER],
];
for (const [from,to,role] of candidacyHappyPath) {
  assert.equal(canTransition('CANDIDACY', from, to, role), true, `expected ${from} -> ${to} for ${role}`);
}

// Human screening is explicitly human-controlled.
assert.equal(canTransition('SCREENING', ScreeningState.NOT_STARTED, ScreeningState.IN_PROGRESS, Roles.RECRUITER), true);
assert.equal(canTransition('SCREENING', ScreeningState.IN_PROGRESS, ScreeningState.QUALIFIED, Roles.RECRUITER), true);
assert.equal(canTransition('SCREENING', ScreeningState.IN_PROGRESS, ScreeningState.QUALIFIED, Roles.AI), false);

// Rejection path.
assert.equal(canTransition('CANDIDACY', CandidacyState.SCREENING, CandidacyState.REJECTED, Roles.RECRUITER), true);
assert.equal(canTransition('CANDIDACY', CandidacyState.CLIENT_SUBMITTED, CandidacyState.REJECTED, Roles.ACCOUNT_MANAGER), true);

// Return-to-recruiter path.
const returnPath = [
  [InternalSubmissionState.DRAFT, InternalSubmissionState.INTERNAL_SUBMITTED, Roles.RECRUITER],
  [InternalSubmissionState.INTERNAL_SUBMITTED, InternalSubmissionState.RETURNED_TO_RECRUITER, Roles.ACCOUNT_MANAGER],
  [InternalSubmissionState.RETURNED_TO_RECRUITER, InternalSubmissionState.INTERNAL_SUBMITTED, Roles.RECRUITER],
  [InternalSubmissionState.INTERNAL_SUBMITTED, InternalSubmissionState.AM_APPROVED, Roles.ACCOUNT_MANAGER],
  [InternalSubmissionState.AM_APPROVED, InternalSubmissionState.CLIENT_SUBMITTED, Roles.ACCOUNT_MANAGER],
];
for (const [from,to,role] of returnPath) assert.equal(canTransition('INTERNAL_SUBMISSION', from, to, role), true);
assert.equal(canTransition('AM_REVIEW', AmReviewState.PENDING, AmReviewState.RETURNED_TO_RECRUITER, Roles.ACCOUNT_MANAGER), true);
assert.equal(canTransition('AM_REVIEW', AmReviewState.RETURNED_TO_RECRUITER, AmReviewState.PENDING, Roles.RECRUITER), true);

// Invalid transitions and ownership confusion are rejected.
assert.equal(canTransition('CANDIDACY', CandidacyState.SOURCED, CandidacyState.CLIENT_SUBMITTED, Roles.RECRUITER), false);
assert.equal(canTransition('CANDIDACY', CandidacyState.AM_REVIEW, CandidacyState.CLIENT_SUBMITTED, Roles.RECRUITER), false);
assert.equal(canTransition('INTERNAL_SUBMISSION', InternalSubmissionState.INTERNAL_SUBMITTED, InternalSubmissionState.AM_APPROVED, Roles.RECRUITER), false);
assert.equal(canTransition('INTERNAL_SUBMISSION', InternalSubmissionState.DRAFT, InternalSubmissionState.CLIENT_SUBMITTED, Roles.ACCOUNT_MANAGER), false);
assert.equal(canTransition('INTERVIEW', InterviewState.NOT_SCHEDULED, InterviewState.COMPLETED, Roles.ACCOUNT_MANAGER), false);
assert.equal(canTransition('OFFER', OfferState.DRAFT, OfferState.SENT, Roles.ACCOUNT_MANAGER), false);
assert.equal(canTransition('JOINING', JoiningState.NOT_STARTED, JoiningState.JOINED, Roles.ACCOUNT_MANAGER), false);
assert.throws(
  () => assertTransition({machine:'CANDIDACY',from:CandidacyState.SOURCED,to:CandidacyState.OFFER,role:Roles.RECRUITER}),
  (error) => error?.code === 'INVALID_WORKFLOW_TRANSITION'
);

// Client submission lifecycle is not a recruiter lifecycle.
assert.equal(canTransition('CLIENT_SUBMISSION', ClientSubmissionState.NOT_SUBMITTED, ClientSubmissionState.SUBMITTED, Roles.ACCOUNT_MANAGER), true);
assert.equal(canTransition('CLIENT_SUBMISSION', ClientSubmissionState.NOT_SUBMITTED, ClientSubmissionState.SUBMITTED, Roles.RECRUITER), false);

// AI is advisory/analytical, never the irreversible human gate.
for (const forbidden of [
  'APPROVE_HIRING_BRIEF','MAKE_FINAL_SCREENING_DECISION','CLIENT_SUBMIT_WITHOUT_AM',
  'MAKE_IRREVERSIBLE_HIRING_DECISION','ACCEPT_OFFER_FOR_CANDIDATE','CONFIRM_JOINING',
  'BYPASS_TENANT_OR_ROLE_BOUNDARY',
]) assert.ok(AiBoundaries.MUST_NOT.includes(forbidden), `AI boundary missing ${forbidden}`);

// Every critical event family has a canonical vocabulary.
for (const event of [
  'requirement.jd_received','requirement.am_approved','candidate.sourced','screening.started',
  'screening.qualified','submission.internal_submitted','submission.am_returned',
  'submission.am_approved','submission.client_submitted','client.feedback_received',
  'interview.scheduled','offer.created','offer.accepted','joining.joined',
]) assert.ok(AuditEvents.includes(event), `missing audit event ${event}`);

// Audit context is explicit: actor + timestamp + organization + entity.
assert.deepEqual(requiredAuditContext({
  actorId:'user-1',actorType:'HUMAN',organizationId:'org-1',
  entityType:'candidacy',entityId:'cand-1',occurredAt:'2026-09-25T00:00:00Z',
}), []);
assert.deepEqual(
  requiredAuditContext({actorId:'user-1',entityType:'candidacy',entityId:'cand-1'}).sort(),
  ['actorType','occurredAt','organizationId'].sort()
);
for (const key of ['organizationId','actorId','actorType','entityType','entityId','occurredAt']) {
  assert.ok(MinimumDataContract.AUDIT_EVENT.includes(key), `audit data contract missing ${key}`);
}

// Repository enforcement checks.
const migration = fs.readFileSync('supabase/migrations/20260926152509_20260925_step1_workflow_contract_lock.sql','utf8');
const ats = fs.readFileSync('lib/ats.js','utf8');
const drawer = fs.readFileSync('app/components/ApplicationScreeningDrawer.js','utf8');
const submissionUi = fs.readFileSync('app/components/SubmissionPackWorkspace.js','utf8');
const api = fs.readFileSync('app/api/ats/route.js','utf8');

for (const token of [
  'xzrecruiter_move_application_workflow','invalid_workflow_transition',
  'submission.internal_submitted','submission.am_approved','submission.am_returned',
  'submission.client_submitted','am_quality_gate_required','ACCOUNT_MANAGER',
  'agency_id=v_agency','actor_user_id',
]) assert.ok(migration.includes(token), `migration contract missing ${token}`);

assert.ok(migration.includes('revoke execute on function public.xzrecruiter_move_application_stage'), 'unguarded legacy stage movement must be revoked');
assert.ok(migration.includes("v_workflow_status in ('AM_APPROVED','AM_REJECTED','CLIENT_SUBMITTED')"), 'terminal submission states must not reopen as fresh recruiter drafts');
assert.ok(ats.includes("moveApplication: ['xzrecruiter_move_application_workflow'"), 'API wrapper must use canonical transition guard');
assert.ok(ats.includes('reviewInternalSubmission') && ats.includes('markClientSubmitted'), 'AM review/client release API boundaries missing');
assert.ok(submissionUi.includes('Send internally to Account Manager') && submissionUi.includes('Send to AM Quality Gate'), 'recruiter handoff copy missing');
assert.ok(!drawer.includes('Submit to client') && submissionUi.includes("!isAm&&current.id&&['DRAFT','RETURNED_TO_RECRUITER'].includes(workflow)"), 'recruiter UI must not directly submit to client');
assert.ok(api.includes('invalid_workflow_transition') && api.includes('am_quality_gate_required'), 'workflow errors must be explicit at API boundary');
assert.ok(!/\bdrop\s+table\b|\btruncate\b|alter\s+table\s+[^;]+\s+drop\s+column/i.test(migration), 'Step-1 migration must not destroy valid existing data');

console.log('STEP1_WORKFLOW_CONTRACT_PASS flow=locked roles=separated ai=bounded transitions=guarded audit=contextualized paths=happy,rejection,return,invalid');
