import { sessionToken } from '@/lib/auth';
import { rpc } from '@/lib/supabase-api';

export async function getAtsContext(module, query = '', limit = 50, offset = 0) {
  const token = await sessionToken();
  if (!token) return null;
  const result = await rpc('xzrecruiter_ats_context', { p_token: token, p_module: module, p_query: query, p_limit: limit, p_offset: offset });
  if(!result?.ok)return null;
  if(String(module).toUpperCase()==='PIPELINE'&&result.rows?.length){
    const facts=await rpc('xzrecruiter_staffing_stage_facts',{p_token:token,p_application_ids:result.rows.slice(0,100).map(r=>r.id)}).catch(()=>null);
    if(facts?.ok){const byId=new Map(facts.rows.map(r=>[r.id,r]));return {...result,rows:result.rows.map(r=>({...r,...byId.get(r.id)})),staffingFactsAvailable:true};}
  }
  return result;
}

export async function getCandidateSearch(query = '', filters = {}, limit = 50, offset = 0) {
  const token = await sessionToken();
  if (!token) return null;
  const result = await rpc('xzrecruiter_candidate_search', { p_token: token, p_query: query, p_filters: filters || {}, p_limit: limit, p_offset: offset });
  return result?.ok ? result : null;
}

export async function getJobSearch(query = '', filters = {}, limit = 50, offset = 0) {
  const token = await sessionToken();
  if (!token) return null;
  const result = await rpc('xzrecruiter_job_search', { p_token: token, p_query: query, p_filters: filters || {}, p_limit: limit, p_offset: offset });
  return result?.ok ? result : null;
}

export async function getSavedViews(module) {
  const token = await sessionToken();
  if (!token) return [];
  const result = await rpc('xzrecruiter_saved_view_context', { p_token: token, p_module: module });
  return result?.ok ? (result.views || []) : [];
}

export async function atsAction(name, args = {}) {
  const token = await sessionToken();
  if (!token) return { ok: false, error: 'unauthorized' };
  const map = {
    transferCandidateOwner: ['xzrecruiter_transfer_candidate_owner', {p_token:token,p_candidate_id:args.candidateId,p_owner_user_id:args.ownerUserId||null,p_expected_owner_user_id:args.expectedOwnerUserId||null,p_reason:args.reason||null}],
    requirementCommercial: ['xzrecruiter_requirement_commercial', {p_token:token,p_job_id:args.jobId,p_values:args.values||null}],
    communicationTimeline: ['xzrecruiter_communication_timeline', {p_token:token,p_job_id:args.jobId,p_candidate_id:args.candidateId||null,p_entry:args.entry||null}],
    saveCandidate: ['xzrecruiter_save_candidate', { p_token: token, p_candidate: args }],
    candidateProfileContext: ['xzrecruiter_candidate_profile_context', { p_token: token, p_candidate_id: args.candidateId }],
    updateCandidateProfile: ['xzrecruiter_update_candidate_profile', { p_token: token, p_candidate_id: args.candidateId, p_profile: args.profile || {} }],
    archiveCandidate: ['xzrecruiter_archive_candidate', { p_token: token, p_candidate_id: args.candidateId }],
    saveJob: ['xzrecruiter_save_job', { p_token: token, p_job: args }],
    jobProfileContext: ['xzrecruiter_job_profile_context', { p_token: token, p_job_id: args.jobId }],
    updateJobProfile: ['xzrecruiter_update_job_profile', { p_token: token, p_job_id: args.jobId, p_job: args.job || {} }],
    createApplication: ['xzrecruiter_create_application', { p_token: token, p_candidate_id: args.candidateId, p_job_id: args.jobId }],
    moveApplication: ['xzrecruiter_move_application_workflow', { p_token: token, p_application_id: args.applicationId, p_stage_id: args.stageId, p_reason: args.reason || null }],
    screeningContext: ['xzrecruiter_screening_context', { p_token: token, p_application_id: args.applicationId }],
    startScreening: ['xzrecruiter_start_screening', { p_token: token, p_application_id: args.applicationId, p_idempotency_key: args.idempotencyKey }],
    saveScreeningProgress: ['xzrecruiter_save_screening_progress', { p_token: token, p_session_id: args.sessionId, p_expected_version: args.expectedVersion, p_payload: args.payload || {}, p_idempotency_key: args.idempotencyKey }],
    completeScreening: ['xzrecruiter_complete_screening', { p_token: token, p_session_id: args.sessionId, p_expected_version: args.expectedVersion, p_outcome: args.outcome, p_override: args.override || {}, p_idempotency_key: args.idempotencyKey }],
    createScreeningFollowup: ['xzrecruiter_create_screening_followup', { p_token: token, p_session_id: args.sessionId, p_followup: args.followup || {}, p_idempotency_key: args.idempotencyKey }],
    scheduleInterview: ['xzrecruiter_schedule_interview', { p_token: token, p_interview: args }],
    saveOffer: ['xzrecruiter_save_offer', { p_token: token, p_offer: args }],
    placementStatus: ['xzrecruiter_placement_status', {p_token:token,p_id:args.placementId,p_expected_status:args.expectedStatus,p_status:args.status,p_reason:args.reason}],
    createPlacement: ['xzrecruiter_create_placement', { p_token: token, p_placement: args }],
    portalAccess: ['xzrecruiter_issue_candidate_portal_access', { p_token: token, p_candidate_id: args.candidateId }],
    prepareResumeUpload: ['xzrecruiter_prepare_candidate_document', { p_token: token, p_candidate_id: args.candidateId, p_filename: args.filename, p_mime_type: args.mimeType, p_size_bytes: args.sizeBytes, p_checksum: args.checksum }],
    finalizeResumeParse: ['xzrecruiter_finalize_candidate_parse', { p_token: token, p_parse_run_id: args.parseRunId, p_extracted_data: args.extractedData || {}, p_field_confidence: args.fieldConfidence || {}, p_field_evidence: args.fieldEvidence || {}, p_error: args.error || null }],
    applyResumeParse: ['xzrecruiter_apply_candidate_parse', { p_token: token, p_parse_run_id: args.parseRunId, p_fields: args.fields || {} }],
    candidateCloseout: ['xzrecruiter_candidate_closeout_context', { p_token: token, p_candidate_id: args.candidateId }],
    talentPoolMembership: ['xzrecruiter_add_candidate_to_pool', { p_token: token, p_candidate_id: args.candidateId, p_pool_id: args.poolId, p_add: args.add !== false }],
    createTalentPool: ['xzrecruiter_create_talent_pool', { p_token: token, p_name: args.name, p_description: args.description || null }],
    mergeCandidates: ['xzrecruiter_merge_candidates', { p_token: token, p_survivor_id: args.survivorId, p_duplicate_id: args.duplicateId, p_resolution: args.resolution || {} }],
    bulkCandidateAction: ['xzrecruiter_bulk_candidate_action', { p_token: token, p_candidate_ids: args.candidateIds || [], p_action: args.action, p_value: args.value || {} }],
    candidateExport: ['xzrecruiter_candidate_export', { p_token: token, p_candidate_ids: args.candidateIds || [] }],
    bulkJobAction: ['xzrecruiter_bulk_job_action', { p_token: token, p_job_ids: args.jobIds || [], p_action: args.action, p_value: args.value || {} }],
    applicationCloseout: ['xzrecruiter_application_closeout_context', { p_token: token, p_application_id: args.applicationId }],
    saveCandidateSubmission: ['xzrecruiter_save_candidate_submission', { p_token: token, p_application_id: args.applicationId, p_submission: args.submission || {}, p_submit: args.submit === true }],
    reviewInternalSubmission: ['xzrecruiter_review_internal_submission', { p_token: token, p_submission_id: args.submissionId, p_action: args.action, p_note: args.note || null }],
    markClientSubmitted: ['xzrecruiter_mark_client_submitted', { p_token: token, p_submission_id: args.submissionId }],
    saveScreeningAnswers: ['xzrecruiter_save_screening_answers', { p_token: token, p_application_id: args.applicationId, p_answers: args.answers || [] }],
    scorecardContext: ['xzrecruiter_scorecard_context', { p_token: token, p_interview_id: args.interviewId || null, p_application_id: args.applicationId || null }],
    submitScorecard: ['xzrecruiter_submit_scorecard', { p_token: token, p_interview_id: args.interviewId, p_template_id: args.templateId, p_ratings: args.ratings || [], p_recommendation: args.recommendation || null, p_comments: args.comments || null, p_submit: args.submit !== false }],
    saveScorecardTemplate: ['xzrecruiter_save_scorecard_template', { p_token: token, p_template: args }],
    saveSavedView: ['xzrecruiter_save_saved_view', { p_token: token, p_view: args }],
    archiveSavedView: ['xzrecruiter_archive_saved_view', { p_token: token, p_view_id: args.viewId }],
    candidateDocumentAccess: ['xzrecruiter_candidate_document_access', { p_token: token, p_document_id: args.documentId }],
    offerCloseout: ['xzrecruiter_offer_closeout_context', { p_token: token, p_offer_id: args.offerId }],
    offerApproval: ['xzrecruiter_offer_approval_action', { p_token: token, p_offer_id: args.offerId, p_action: args.action, p_note: args.note || null }],
    offerStatus: ['xzrecruiter_offer_set_status', { p_token: token, p_offer_id: args.offerId, p_status: args.status }],
    attachmentContext: ['xzrecruiter_attachment_context', { p_token: token, p_entity_type: args.entityType, p_entity_id: args.entityId }],
    prepareAttachment: ['xzrecruiter_prepare_attachment', { p_token: token, p_entity_type: args.entityType, p_entity_id: args.entityId, p_filename: args.filename, p_mime_type: args.mimeType, p_size_bytes: args.sizeBytes }],
    attachmentAccess: ['xzrecruiter_attachment_access', { p_token: token, p_attachment_id: args.attachmentId }],
    archiveAttachment: ['xzrecruiter_archive_attachment', { p_token: token, p_attachment_id: args.attachmentId }],
    noteContext: ['xzrecruiter_note_context', { p_token: token, p_entity_type: args.entityType, p_entity_id: args.entityId }],
    saveNote: ['xzrecruiter_save_note', { p_token: token, p_entity_type: args.entityType, p_entity_id: args.entityId, p_note: args.note }],
    archiveNote: ['xzrecruiter_archive_note', { p_token: token, p_note_id: args.noteId }]
  };
  const entry = map[name];
  if (!entry) return { ok: false, error: 'unsupported_action' };
  return rpc(entry[0], entry[1]);
}
