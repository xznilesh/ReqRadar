import { sessionToken } from '@/lib/auth';
import { rpc } from '@/lib/supabase-api';

export async function getRecruiterHome(limit=50){
  const token=await sessionToken();
  if(!token)return null;
  const result=await rpc('xzrecruiter_recruiter_home',{p_token:token,p_limit:Number(limit||50)});
  return result?.ok?result:null;
}

export async function getRecruiterRequirement(jobId,limit=50){
  const token=await sessionToken();
  if(!token)return null;
  const result=await rpc('xzrecruiter_recruiter_requirement_context',{p_token:token,p_job_id:jobId,p_queue_limit:Number(limit||50)});
  if(!result?.ok)return null;
  const rediscovery=await rpc('xzrecruiter_talent_match_search',{p_token:token,p_job_id:jobId,p_query:'',p_limit:30}).catch(()=>null);
  return {...result,rediscovery:rediscovery?.ok?rediscovery:{ok:false,rows:[],error:rediscovery?.error||'rediscovery_unavailable'}};
}

export async function recruiterAction(name,args={}){
  const token=await sessionToken();
  if(!token)return {ok:false,error:'unauthorized'};
  const map={
    saveAssignment:['xzrecruiter_save_requirement_assignment',{
      p_token:token,p_job_id:args.jobId,p_recruiter_user_id:args.recruiterUserId,
      p_daily_target:Number(args.dailyTarget||0),p_total_target:Number(args.totalTarget||0),
      p_status:args.status||'ACTIVE',p_priority_context:args.priorityContext||null,
      p_manager_instructions:args.managerInstructions||null,p_idempotency_key:args.idempotencyKey||null,
      p_assignment_priority:args.priority||null,p_blocker_type:args.blockerType||null,
      p_blocker_reason:args.blockerReason||null,p_blocker_owner_user_id:args.blockerOwnerUserId||null
    }],
    setRequirementTarget:['xzrecruiter_set_requirement_daily_target',{
      p_token:token,p_job_id:args.jobId,p_daily_target:Number(args.dailyTarget||0),p_total_target:Number(args.totalTarget||0)
    }],
    candidateSearch:['xzrecruiter_recruiter_candidate_search',{
      p_token:token,p_job_id:args.jobId,p_query:args.query||'',p_limit:Number(args.limit||20)
    }],
    intakeCandidate:['xzrecruiter_recruiter_intake_candidate',{
      p_token:token,p_job_id:args.jobId,p_candidate:args.candidate||{},
      p_source_type:args.sourceType,p_source_reference:args.sourceReference||null,
      p_sourcing_notes:args.sourcingNotes||null,p_idempotency_key:args.idempotencyKey||null
    }],
    saveTask:['xzrecruiter_save_execution_task',{p_token:token,p_task:args.task||{}}],
    setTaskStatus:['xzrecruiter_set_execution_task_status',{p_token:token,p_task_id:args.taskId,p_status:args.status}],
    prepareResume:['xzrecruiter_prepare_execution_resume',{
      p_token:token,p_job_id:args.jobId,p_candidate_id:args.candidateId,p_filename:args.filename,
      p_mime_type:args.mimeType,p_size_bytes:Number(args.sizeBytes||0),p_checksum:args.checksum
    }],
    finalizeResume:['xzrecruiter_finalize_execution_resume',{
      p_token:token,p_job_id:args.jobId,p_parse_run_id:args.parseRunId,
      p_extracted_data:args.extractedData||{},p_field_confidence:args.fieldConfidence||{},
      p_field_evidence:args.fieldEvidence||{},p_error:args.error||null
    }]
  };
  const entry=map[name];
  if(!entry)return {ok:false,error:'unsupported_action'};
  return rpc(entry[0],entry[1]);
}
