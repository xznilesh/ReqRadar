export const WORKFLOW_VERSION = 'xzrecruiter-step1-v1';

export const Roles = Object.freeze({
  OWNER: 'OWNER',
  ADMIN: 'ADMIN',
  ACCOUNT_MANAGER: 'ACCOUNT_MANAGER',
  RECRUITMENT_MANAGER: 'RECRUITMENT_MANAGER',
  RECRUITER: 'RECRUITER',
  COMPLIANCE_REVIEWER: 'COMPLIANCE_REVIEWER',
  CLIENT: 'CLIENT',
  AI: 'AI',
});

export const HumanRoles = Object.freeze([
  Roles.OWNER,
  Roles.ADMIN,
  Roles.ACCOUNT_MANAGER,
  Roles.RECRUITMENT_MANAGER,
  Roles.RECRUITER,
  Roles.COMPLIANCE_REVIEWER,
  Roles.CLIENT,
]);

export const CanonicalFlow = Object.freeze([
  'CLIENT_JD',
  'AM_RECEIVES_REQUIREMENT',
  'AI_HIRING_BRIEF',
  'AM_CONFIRMS_CLIENT_INTENT',
  'RECRUITER_SOURCING',
  'CANDIDATE_IN_XZ_RECRUITER',
  'AI_CANDIDATE_ANALYSIS',
  'HUMAN_SCREENING',
  'INTERNAL_SUBMISSION',
  'AI_SUBMISSION_PACK',
  'AM_QUALITY_GATE',
  'CLIENT_SUBMISSION',
  'INTERVIEW',
  'OFFER',
  'JOINING',
  'ANALYTICS_LEARNING_LOOP',
]);

export const RequirementState = Object.freeze({
  JD_RECEIVED: 'JD_RECEIVED',
  AI_BRIEF_PENDING: 'AI_BRIEF_PENDING',
  AM_REVIEW: 'AM_REVIEW',
  APPROVED: 'APPROVED',
  OPEN: 'OPEN',
  CHANGE_PENDING_AM_CONFIRMATION: 'CHANGE_PENDING_AM_CONFIRMATION',
  ON_HOLD: 'ON_HOLD',
  CLOSED: 'CLOSED',
  CANCELLED: 'CANCELLED',
});

export const CandidacyState = Object.freeze({
  SOURCED: 'SOURCED',
  AI_ANALYSIS_PENDING: 'AI_ANALYSIS_PENDING',
  READY_FOR_HUMAN_SCREEN: 'READY_FOR_HUMAN_SCREEN',
  SCREENING: 'SCREENING',
  QUALIFIED: 'QUALIFIED',
  INTERNAL_SUBMISSION: 'INTERNAL_SUBMISSION',
  AM_REVIEW: 'AM_REVIEW',
  CLIENT_SUBMITTED: 'CLIENT_SUBMITTED',
  INTERVIEW: 'INTERVIEW',
  OFFER: 'OFFER',
  JOINING: 'JOINING',
  JOINED: 'JOINED',
  REJECTED: 'REJECTED',
  WITHDRAWN: 'WITHDRAWN',
});

export const ScreeningState = Object.freeze({
  NOT_STARTED: 'NOT_STARTED',
  IN_PROGRESS: 'IN_PROGRESS',
  NEEDS_CLARIFICATION: 'NEEDS_CLARIFICATION',
  QUALIFIED: 'QUALIFIED',
  NOT_QUALIFIED: 'NOT_QUALIFIED',
  CANDIDATE_WITHDREW: 'CANDIDATE_WITHDREW',
});

export const InternalSubmissionState = Object.freeze({
  DRAFT: 'DRAFT',
  INTERNAL_SUBMITTED: 'INTERNAL_SUBMITTED',
  RETURNED_TO_RECRUITER: 'RETURNED_TO_RECRUITER',
  AM_APPROVED: 'AM_APPROVED',
  AM_REJECTED: 'AM_REJECTED',
  CLIENT_SUBMITTED: 'CLIENT_SUBMITTED',
});

export const AmReviewState = Object.freeze({
  NOT_REQUESTED: 'NOT_REQUESTED',
  PENDING: 'PENDING',
  RETURNED_TO_RECRUITER: 'RETURNED_TO_RECRUITER',
  APPROVED: 'APPROVED',
  REJECTED: 'REJECTED',
});

export const ClientSubmissionState = Object.freeze({
  NOT_SUBMITTED: 'NOT_SUBMITTED',
  SUBMITTED: 'SUBMITTED',
  VIEWED: 'VIEWED',
  FEEDBACK_PENDING: 'FEEDBACK_PENDING',
  INTERVIEW_REQUESTED: 'INTERVIEW_REQUESTED',
  REJECTED: 'REJECTED',
  WITHDRAWN: 'WITHDRAWN',
});

export const InterviewState = Object.freeze({
  NOT_SCHEDULED: 'NOT_SCHEDULED',
  SCHEDULED: 'SCHEDULED',
  RESCHEDULED: 'RESCHEDULED',
  COMPLETED: 'COMPLETED',
  CANCELLED: 'CANCELLED',
  NO_SHOW: 'NO_SHOW',
});

export const OfferState = Object.freeze({
  NOT_CREATED: 'NOT_CREATED',
  DRAFT: 'DRAFT',
  INTERNAL_APPROVAL_PENDING: 'INTERNAL_APPROVAL_PENDING',
  APPROVED: 'APPROVED',
  SENT: 'SENT',
  VIEWED: 'VIEWED',
  ACCEPTED: 'ACCEPTED',
  DECLINED: 'DECLINED',
  WITHDRAWN: 'WITHDRAWN',
  EXPIRED: 'EXPIRED',
});

export const JoiningState = Object.freeze({
  NOT_STARTED: 'NOT_STARTED',
  PRE_JOINING: 'PRE_JOINING',
  CONFIRMED: 'CONFIRMED',
  JOINED: 'JOINED',
  DID_NOT_JOIN: 'DID_NOT_JOIN',
  CANCELLED: 'CANCELLED',
});

const transition = (from, to, roles) => Object.freeze({ from, to, roles: Object.freeze(roles) });

export const StateMachines = Object.freeze({
  REQUIREMENT: Object.freeze([
    transition(RequirementState.JD_RECEIVED, RequirementState.AI_BRIEF_PENDING, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.AI_BRIEF_PENDING, RequirementState.AM_REVIEW, [Roles.AI]),
    transition(RequirementState.AM_REVIEW, RequirementState.APPROVED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.AM_REVIEW, RequirementState.AI_BRIEF_PENDING, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.APPROVED, RequirementState.OPEN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.OPEN, RequirementState.CHANGE_PENDING_AM_CONFIRMATION, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.CHANGE_PENDING_AM_CONFIRMATION, RequirementState.OPEN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.OPEN, RequirementState.ON_HOLD, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.ON_HOLD, RequirementState.OPEN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.OPEN, RequirementState.CLOSED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(RequirementState.OPEN, RequirementState.CANCELLED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  CANDIDACY: Object.freeze([
    transition(CandidacyState.SOURCED, CandidacyState.AI_ANALYSIS_PENDING, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.AI_ANALYSIS_PENDING, CandidacyState.READY_FOR_HUMAN_SCREEN, [Roles.AI]),
    transition(CandidacyState.READY_FOR_HUMAN_SCREEN, CandidacyState.SCREENING, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.SCREENING, CandidacyState.QUALIFIED, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.SCREENING, CandidacyState.REJECTED, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.SCREENING, CandidacyState.WITHDRAWN, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.QUALIFIED, CandidacyState.INTERNAL_SUBMISSION, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.INTERNAL_SUBMISSION, CandidacyState.AM_REVIEW, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.AM_REVIEW, CandidacyState.QUALIFIED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.AM_REVIEW, CandidacyState.CLIENT_SUBMITTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.AM_REVIEW, CandidacyState.REJECTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.CLIENT_SUBMITTED, CandidacyState.INTERVIEW, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.CLIENT_SUBMITTED, CandidacyState.REJECTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.INTERVIEW, CandidacyState.OFFER, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.INTERVIEW, CandidacyState.REJECTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.OFFER, CandidacyState.JOINING, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.JOINING, CandidacyState.JOINED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(CandidacyState.JOINING, CandidacyState.WITHDRAWN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  SCREENING: Object.freeze([
    transition(ScreeningState.NOT_STARTED, ScreeningState.IN_PROGRESS, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ScreeningState.IN_PROGRESS, ScreeningState.NEEDS_CLARIFICATION, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ScreeningState.NEEDS_CLARIFICATION, ScreeningState.IN_PROGRESS, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ScreeningState.IN_PROGRESS, ScreeningState.QUALIFIED, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ScreeningState.IN_PROGRESS, ScreeningState.NOT_QUALIFIED, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ScreeningState.IN_PROGRESS, ScreeningState.CANDIDATE_WITHDREW, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  INTERNAL_SUBMISSION: Object.freeze([
    transition(InternalSubmissionState.DRAFT, InternalSubmissionState.INTERNAL_SUBMITTED, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InternalSubmissionState.RETURNED_TO_RECRUITER, InternalSubmissionState.INTERNAL_SUBMITTED, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InternalSubmissionState.INTERNAL_SUBMITTED, InternalSubmissionState.RETURNED_TO_RECRUITER, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InternalSubmissionState.INTERNAL_SUBMITTED, InternalSubmissionState.AM_APPROVED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InternalSubmissionState.INTERNAL_SUBMITTED, InternalSubmissionState.AM_REJECTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InternalSubmissionState.AM_APPROVED, InternalSubmissionState.CLIENT_SUBMITTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  AM_REVIEW: Object.freeze([
    transition(AmReviewState.NOT_REQUESTED, AmReviewState.PENDING, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(AmReviewState.PENDING, AmReviewState.RETURNED_TO_RECRUITER, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(AmReviewState.RETURNED_TO_RECRUITER, AmReviewState.PENDING, [Roles.RECRUITER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(AmReviewState.PENDING, AmReviewState.APPROVED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(AmReviewState.PENDING, AmReviewState.REJECTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  CLIENT_SUBMISSION: Object.freeze([
    transition(ClientSubmissionState.NOT_SUBMITTED, ClientSubmissionState.SUBMITTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.SUBMITTED, ClientSubmissionState.VIEWED, [Roles.CLIENT, Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.SUBMITTED, ClientSubmissionState.FEEDBACK_PENDING, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.VIEWED, ClientSubmissionState.FEEDBACK_PENDING, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.SUBMITTED, ClientSubmissionState.INTERVIEW_REQUESTED, [Roles.CLIENT, Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.VIEWED, ClientSubmissionState.INTERVIEW_REQUESTED, [Roles.CLIENT, Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.SUBMITTED, ClientSubmissionState.REJECTED, [Roles.CLIENT, Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.VIEWED, ClientSubmissionState.REJECTED, [Roles.CLIENT, Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(ClientSubmissionState.SUBMITTED, ClientSubmissionState.WITHDRAWN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  INTERVIEW: Object.freeze([
    transition(InterviewState.NOT_SCHEDULED, InterviewState.SCHEDULED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InterviewState.SCHEDULED, InterviewState.RESCHEDULED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InterviewState.RESCHEDULED, InterviewState.SCHEDULED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InterviewState.SCHEDULED, InterviewState.COMPLETED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InterviewState.SCHEDULED, InterviewState.CANCELLED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(InterviewState.SCHEDULED, InterviewState.NO_SHOW, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  OFFER: Object.freeze([
    transition(OfferState.NOT_CREATED, OfferState.DRAFT, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.DRAFT, OfferState.INTERNAL_APPROVAL_PENDING, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.INTERNAL_APPROVAL_PENDING, OfferState.APPROVED, [Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.INTERNAL_APPROVAL_PENDING, OfferState.DRAFT, [Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.APPROVED, OfferState.SENT, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.SENT, OfferState.VIEWED, [Roles.ACCOUNT_MANAGER, Roles.CLIENT, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.SENT, OfferState.ACCEPTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.VIEWED, OfferState.ACCEPTED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.SENT, OfferState.DECLINED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.VIEWED, OfferState.DECLINED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.SENT, OfferState.WITHDRAWN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.VIEWED, OfferState.WITHDRAWN, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(OfferState.SENT, OfferState.EXPIRED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
  JOINING: Object.freeze([
    transition(JoiningState.NOT_STARTED, JoiningState.PRE_JOINING, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(JoiningState.PRE_JOINING, JoiningState.CONFIRMED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(JoiningState.CONFIRMED, JoiningState.JOINED, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(JoiningState.PRE_JOINING, JoiningState.DID_NOT_JOIN, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(JoiningState.CONFIRMED, JoiningState.DID_NOT_JOIN, [Roles.ACCOUNT_MANAGER, Roles.RECRUITMENT_MANAGER, Roles.OWNER, Roles.ADMIN]),
    transition(JoiningState.PRE_JOINING, JoiningState.CANCELLED, [Roles.ACCOUNT_MANAGER, Roles.OWNER, Roles.ADMIN]),
  ]),
});

export const Permission = Object.freeze({
  MANAGE_ORG: 'MANAGE_ORG',
  MANAGE_ROLES: 'MANAGE_ROLES',
  MANAGE_REQUIREMENT: 'MANAGE_REQUIREMENT',
  APPROVE_HIRING_BRIEF: 'APPROVE_HIRING_BRIEF',
  ASSIGN_RECRUITER: 'ASSIGN_RECRUITER',
  SOURCE_CANDIDATE: 'SOURCE_CANDIDATE',
  SCREEN_CANDIDATE: 'SCREEN_CANDIDATE',
  QUALIFY_CANDIDATE: 'QUALIFY_CANDIDATE',
  INTERNAL_SUBMIT: 'INTERNAL_SUBMIT',
  AM_QUALITY_GATE: 'AM_QUALITY_GATE',
  CLIENT_SUBMIT: 'CLIENT_SUBMIT',
  CLIENT_FEEDBACK: 'CLIENT_FEEDBACK',
  MANAGE_INTERVIEW: 'MANAGE_INTERVIEW',
  MANAGE_OFFER: 'MANAGE_OFFER',
  CONFIRM_JOINING: 'CONFIRM_JOINING',
  REVIEW_COMPLIANCE: 'REVIEW_COMPLIANCE',
  VIEW_AUDIT: 'VIEW_AUDIT',
});

export const RolePermissions = Object.freeze({
  [Roles.OWNER]: Object.freeze(Object.values(Permission)),
  [Roles.ADMIN]: Object.freeze(Object.values(Permission)),
  [Roles.ACCOUNT_MANAGER]: Object.freeze([
    Permission.MANAGE_REQUIREMENT, Permission.APPROVE_HIRING_BRIEF, Permission.ASSIGN_RECRUITER,
    Permission.AM_QUALITY_GATE, Permission.CLIENT_SUBMIT, Permission.CLIENT_FEEDBACK,
    Permission.MANAGE_INTERVIEW, Permission.MANAGE_OFFER, Permission.CONFIRM_JOINING, Permission.VIEW_AUDIT,
  ]),
  [Roles.RECRUITMENT_MANAGER]: Object.freeze([
    Permission.ASSIGN_RECRUITER, Permission.SOURCE_CANDIDATE, Permission.SCREEN_CANDIDATE,
    Permission.QUALIFY_CANDIDATE, Permission.INTERNAL_SUBMIT, Permission.MANAGE_INTERVIEW,
    Permission.CONFIRM_JOINING, Permission.VIEW_AUDIT,
  ]),
  [Roles.RECRUITER]: Object.freeze([
    Permission.SOURCE_CANDIDATE, Permission.SCREEN_CANDIDATE, Permission.QUALIFY_CANDIDATE,
    Permission.INTERNAL_SUBMIT,
  ]),
  [Roles.COMPLIANCE_REVIEWER]: Object.freeze([Permission.REVIEW_COMPLIANCE, Permission.VIEW_AUDIT]),
  [Roles.CLIENT]: Object.freeze([Permission.CLIENT_FEEDBACK]),
  [Roles.AI]: Object.freeze([]),
});

export const AiBoundaries = Object.freeze({
  MAY: Object.freeze([
    'ANALYZE_JD', 'EXTRACT_REQUIREMENTS', 'DRAFT_HIRING_BRIEF', 'DRAFT_IDEAL_PROFILE',
    'FLAG_HARD_REQUIREMENTS', 'ANALYZE_CANDIDATE', 'EXPLAIN_FIT_GAPS', 'DETECT_DUPLICATES',
    'GENERATE_SCREENING_GUIDANCE', 'DRAFT_SUBMISSION_SUMMARY', 'RECOMMEND_NEXT_ACTION',
  ]),
  MUST_NOT: Object.freeze([
    'APPROVE_HIRING_BRIEF', 'MAKE_FINAL_SCREENING_DECISION', 'CLIENT_SUBMIT_WITHOUT_AM',
    'MAKE_IRREVERSIBLE_HIRING_DECISION', 'ACCEPT_OFFER_FOR_CANDIDATE', 'CONFIRM_JOINING',
    'BYPASS_TENANT_OR_ROLE_BOUNDARY',
  ]),
});

export const AuditEvents = Object.freeze([
  'requirement.jd_received',
  'requirement.ai_brief_requested',
  'requirement.ai_brief_ready',
  'requirement.am_approved',
  'requirement.am_returned',
  'requirement.changed',
  'candidate.sourced',
  'candidate.entered_system',
  'candidate.ai_analysis_requested',
  'candidate.ai_analysis_ready',
  'screening.started',
  'screening.updated',
  'screening.qualified',
  'screening.not_qualified',
  'submission.draft_saved',
  'submission.internal_submitted',
  'submission.am_returned',
  'submission.am_approved',
  'submission.am_rejected',
  'submission.client_submitted',
  'client.feedback_received',
  'interview.scheduled',
  'interview.rescheduled',
  'interview.completed',
  'offer.created',
  'offer.approved',
  'offer.sent',
  'offer.accepted',
  'offer.declined',
  'joining.started',
  'joining.confirmed',
  'joining.joined',
  'joining.did_not_join',
  'workflow.override',
]);

export function hasPermission(role, permission) {
  return Boolean(RolePermissions[role]?.includes(permission));
}

export function canTransition(machine, from, to, role) {
  const transitions = StateMachines[machine];
  if (!transitions) return false;
  return transitions.some((item) => item.from === from && item.to === to && item.roles.includes(role));
}

export function assertTransition({ machine, from, to, role }) {
  if (!canTransition(machine, from, to, role)) {
    const error = new Error(`Invalid ${machine} transition: ${from} -> ${to} by ${role}`);
    error.code = 'INVALID_WORKFLOW_TRANSITION';
    throw error;
  }
  return true;
}

export function requiredAuditContext(input = {}) {
  const required = ['actorId', 'actorType', 'organizationId', 'entityType', 'entityId', 'occurredAt'];
  return required.filter((key) => !input[key]);
}

export const MinimumDataContract = Object.freeze({
  REQUIREMENT: Object.freeze(['id', 'organizationId', 'clientId', 'accountManagerId', 'state', 'rawJdRef', 'version', 'createdAt', 'updatedAt']),
  CANDIDATE: Object.freeze(['id', 'organizationId', 'source', 'sourceRef', 'primaryResumeVersionId', 'createdAt', 'updatedAt']),
  CANDIDACY: Object.freeze(['id', 'organizationId', 'requirementId', 'candidateId', 'recruiterId', 'state', 'createdAt', 'updatedAt']),
  SCREENING: Object.freeze(['id', 'organizationId', 'candidacyId', 'recruiterId', 'state', 'interest', 'communication', 'availability', 'expectations', 'completedAt']),
  INTERNAL_SUBMISSION: Object.freeze(['id', 'organizationId', 'candidacyId', 'resumeVersionId', 'state', 'submittedByRecruiterId', 'submittedAt']),
  AM_REVIEW: Object.freeze(['id', 'organizationId', 'internalSubmissionId', 'accountManagerId', 'state', 'reason', 'reviewedAt']),
  CLIENT_SUBMISSION: Object.freeze(['id', 'organizationId', 'internalSubmissionId', 'clientId', 'submittedByAccountManagerId', 'state', 'submittedAt']),
  INTERVIEW: Object.freeze(['id', 'organizationId', 'candidacyId', 'state', 'scheduledAt', 'timezone']),
  OFFER: Object.freeze(['id', 'organizationId', 'candidacyId', 'state', 'version', 'createdAt']),
  JOINING: Object.freeze(['id', 'organizationId', 'candidacyId', 'offerId', 'state', 'plannedStartDate', 'joinedAt']),
  AUDIT_EVENT: Object.freeze(['id', 'organizationId', 'actorId', 'actorType', 'entityType', 'entityId', 'action', 'occurredAt', 'metadata']),
});

export const ServiceBoundaries = Object.freeze({
  REQUIREMENTS: 'Own requirement lifecycle and AM-confirmed client intent. Step 2 intelligence plugs in later.',
  CANDIDATES: 'Own candidate identity/profile and source provenance; not job-specific decisions.',
  CANDIDACIES: 'Own candidate x requirement lifecycle and recruiter ownership.',
  SCREENING: 'Own human screening facts/decision; AI guidance is advisory input only.',
  SUBMISSIONS: 'Own recruiter internal submission, AM review and client release chain.',
  INTERVIEWS: 'Own interview scheduling/status on the same candidacy chain.',
  OFFERS: 'Own offer versions/status on the same candidacy chain.',
  JOINING: 'Own pre-joining/joined outcome on the same candidacy chain.',
  AUDIT: 'Append critical actor/entity/organization transition context; never act as workflow owner.',
});

// Client feedback uses the existing portal database vocabulary end to end.
export const CLIENT_FEEDBACK_DECISIONS=Object.freeze(['COMMENT','ADVANCE','REQUEST_INTERVIEW','HOLD','REJECT']);
export function clientFeedbackStatus(decision,current='SUBMITTED'){
  return ({ADVANCE:'ADVANCED',REQUEST_INTERVIEW:'INTERVIEW_REQUESTED',HOLD:'ON_HOLD',REJECT:'REJECTED'})[decision]||current;
}

// Display projection only: canonical evidence/AM transition guards remain authoritative.
export const STAFFING_PIPELINE=Object.freeze(['Sourced','Screened','Qualified','Submission Ready','AM Approved','Client Submitted','Client Review','Interview','Offer','Joining','Placed']);
export function staffingStage(row={}){
  const state=String(row.candidacy_state||row.state||row.stage_code||row.stage||'SOURCED').toUpperCase();
  if(['REJECTED','WITHDRAWN'].includes(state))return state==='REJECTED'?'Rejected':'Withdrawn';
  if(['JOINED','PLACED','HIRED'].includes(state)||['STARTED','COMPLETED'].includes(row.placement_status))return 'Placed';
  if(state==='JOINING'||row.placement_status==='PLANNED')return 'Joining';
  if(state==='OFFER')return 'Offer';
  if(state==='INTERVIEW')return 'Interview';
  if(row.workflow_status==='CLIENT_SUBMITTED'||['CLIENT_SUBMITTED','SUBMITTED'].includes(state)){
    return row.client_viewed_at||row.client_feedback_at||['ADVANCED','INTERVIEW_REQUESTED','ON_HOLD'].includes(row.submission_status)?'Client Review':'Client Submitted';
  }
  if(row.workflow_status==='AM_APPROVED'||row.am_review_status==='APPROVED')return 'AM Approved';
  if(['INTERNAL_SUBMISSION','AM_REVIEW'].includes(state)||row.workflow_status==='INTERNAL_SUBMITTED')return 'Submission Ready';
  if(state==='QUALIFIED')return 'Qualified';
  if(row.screening_completed_at||row.screened)return 'Screened';
  return 'Sourced';
}
