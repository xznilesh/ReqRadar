import { NextResponse } from 'next/server';
import { mutationRequestIsTrusted,declaredBodyWithin } from '@/lib/request-security';
import { atsAction } from '@/lib/ats';
import { getRecruiterHome } from '@/lib/recruiter';
import { telemetryError } from '@/lib/telemetry';

function sameOrigin(req) {
  const origin = req.headers.get('origin');
  return !origin || origin === req.nextUrl.origin;
}

function statusFor(error) {
  if (error === 'unauthorized') return 401;
  if (error === 'forbidden' || error === 'stage_role_forbidden' || error === 'recruiter_only' || error === 'am_only' || error === 'interview_role_forbidden' || error === 'offer_role_forbidden' || error === 'joining_role_forbidden' || error === 'approval_forbidden') return 403;
  if (error === 'not_found' || error?.endsWith?.('_not_found')) return 404;
  if (error === 'possible_duplicate' || error === 'application_exists' || error === 'placement_exists' || error === 'already_applied' || error === 'am_review_pending' || error === 'stale_screening_version' || error === 'screening_closed') return 409;
  if (error === 'stage_requirements_missing' || error === 'rejection_reason_required' || error === 'withdrawal_reason_required' || error === 'invalid_workflow_transition' || error === 'am_quality_gate_required' || error === 'submission_not_am_approved' || error === 'review_reason_required' || error === 'noncanonical_stage' || error === 'accepted_offer_required' || error === 'invalid_offer_state' || error === 'offer_must_be_approved' || error === 'candidate_interest_required' || error === 'non_overridable_hard_rule' || error === 'override_reason_required' || error === 'fake_verification_forbidden' || error === 'invalid_screening_outcome' || error === 'qualification_requirements_missing' || error === 'candidate_interest_outcome_mismatch') return 422;
  return 400;
}

export async function POST(req) {
  if(!sameOrigin(req)||!mutationRequestIsTrusted(req))return NextResponse.json({ error: 'Invalid origin.' }, { status: 403 });
  if(!declaredBodyWithin(req,1048576))return NextResponse.json({error:'request_too_large'},{status:413});
  let body;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: 'Invalid request.' }, { status: 400 }); }
  try {
    const action=String(body.action||'');
    const protectedForRecruiter=new Set([
      'saveJob','updateJobProfile','bulkJobAction',
      'saveCandidate','updateCandidateProfile','archiveCandidate','mergeCandidates','bulkCandidateAction',
      'candidateExport','portalAccess','prepareResumeUpload','applyResumeParse','candidateDocumentAccess',
      'talentPoolMembership','createTalentPool','prepareAttachment','attachmentAccess','archiveAttachment'
    ]);
    if(protectedForRecruiter.has(action)){
      const execution=await getRecruiterHome(1).catch(()=>null);
      if(execution?.business_role==='RECRUITER'){
        return NextResponse.json({ok:false,error:'execution_workspace_required'},{status:403});
      }
    }
    const result = await atsAction(action, body.payload || {});
    if (!result?.ok) return NextResponse.json(result || { error: 'Action failed.' }, { status: statusFor(result?.error) });
    return NextResponse.json(result);
  } catch (error) {
    telemetryError('ats_action_failed',error,{action:String(body?.action||'unknown').slice(0,80),status_code:error?.status||503});
    return NextResponse.json({ error: 'Recruitment action is temporarily unavailable.' }, { status: 503 });
  }
}
