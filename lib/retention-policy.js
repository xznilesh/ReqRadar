import { createHash, randomUUID } from 'node:crypto';
import { SUPABASE_URL } from './supabase-api.js';
import { assertSafeStoragePath } from './file-security.js';
import { assertUuid, queryPath, serviceRequest } from './service-store.js';

const SERVICE_KEY=String(process.env.SUPABASE_SERVICE_ROLE_KEY||'').trim();
const BUCKET=String(process.env.XZRECRUITER_SENSITIVE_STORAGE_BUCKET||process.env.XZRECRUITER_STORAGE_BUCKET||'xzrecruiter-private').trim();

function iso(){return new Date().toISOString()}
function hash(value){return createHash('sha256').update(String(value||'')).digest('hex')}
function safeBucket(){if(!/^[A-Za-z0-9][A-Za-z0-9._-]{1,62}$/.test(BUCKET))throw new Error('unsafe_storage_bucket');return BUCKET}
async function updateRows(table,params,body){
  return serviceRequest(queryPath(table,params),{method:'PATCH',body,prefer:'return=representation'});
}
async function deleteRows(table,params){
  return serviceRequest(queryPath(table,params),{method:'DELETE',prefer:'return=representation'});
}
async function storageDelete(path){
  const safePath=assertSafeStoragePath(path);
  if(!SUPABASE_URL||!SERVICE_KEY)throw new Error('retention_storage_not_configured');
  const response=await fetch(`${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(safeBucket())}`,{
    method:'DELETE',
    headers:{apikey:SERVICE_KEY,authorization:`Bearer ${SERVICE_KEY}`,'content-type':'application/json'},
    body:JSON.stringify({prefixes:[safePath]}),cache:'no-store'
  });
  if(!response.ok)throw new Error('retention_storage_delete_failed');
}
async function activeLegalHold(agency,candidate){
  const rows=await serviceRequest(queryPath('candidate_legal_holds',{select:'id,reason,placed_at',agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`,released_at:'is.null',limit:'1'}));
  return Array.isArray(rows)?rows[0]||null:null;
}
async function createRun({agencyId,candidateId,privacyRequestId=null,mode,retentionDays=null}){
  const id=randomUUID();
  await serviceRequest('/rest/v1/candidate_retention_runs',{method:'POST',body:{id,agency_id:agencyId,candidate_id:candidateId,privacy_request_id:privacyRequestId||null,mode,status:'STARTED',policy_retention_days:retentionDays},prefer:'return=minimal'});
  return id;
}
async function finishRun(id,body){
  await updateRows('candidate_retention_runs',{id:`eq.${id}`},{...body,completed_at:iso()});
}
async function audit({agencyId,candidateId,action,metadata}){
  await serviceRequest('/rest/v1/audit_events',{method:'POST',body:{id:randomUUID(),agency_id:agencyId,actor_user_id:null,action,entity_type:'candidate',entity_id:candidateId,metadata},prefer:'return=minimal'});
}
function idFilter(ids,label){
  const clean=[...new Set((ids||[]).filter(Boolean).map(value=>assertUuid(value,label)))];
  return clean.length?`in.(${clean.join(',')})`:null;
}

export async function createPrivacyRequest({agencyId,candidateId,requestType='DELETE',requestedByUserId=null,dueAt=null,legalBasis=null}){
  const agency=assertUuid(agencyId,'agency_id'),candidate=assertUuid(candidateId,'candidate_id');
  const type=String(requestType||'').toUpperCase();
  if(!['ACCESS','PORTABILITY','CORRECTION','RESTRICTION','DELETE'].includes(type))throw new Error('invalid_privacy_request_type');
  const id=randomUUID();
  await serviceRequest('/rest/v1/candidate_privacy_requests',{method:'POST',body:{id,agency_id:agency,candidate_id:candidate,request_type:type,status:'RECEIVED',due_at:dueAt||null,requested_by_user_id:requestedByUserId?assertUuid(requestedByUserId,'requested_by_user_id'):null,legal_basis:legalBasis||null},prefer:'return=minimal'});
  return {id,agencyId:agency,candidateId:candidate,requestType:type};
}

export async function listPrivacyRequests({agencyId,status=null,limit=200}){
  const agency=assertUuid(agencyId,'agency_id');
  const rows=await serviceRequest(queryPath('candidate_privacy_requests',{select:'id,candidate_id,request_type,status,requested_at,due_at,handled_by_user_id,completed_at,legal_basis,result_summary,updated_at',agency_id:`eq.${agency}`,...(status?{status:`eq.${String(status).toUpperCase()}`}:{}),order:'requested_at.desc',limit:String(Math.max(1,Math.min(Number(limit)||200,500)))}));
  return Array.isArray(rows)?rows:[];
}

export async function executeCandidateDeletion({agencyId,candidateId,privacyRequestId=null,execute=false,retentionDays=null}){
  const agency=assertUuid(agencyId,'agency_id'),candidate=assertUuid(candidateId,'candidate_id');
  const requestId=privacyRequestId?assertUuid(privacyRequestId,'privacy_request_id'):null;
  const mode=execute?'EXECUTE':'DRY_RUN';
  const runId=await createRun({agencyId:agency,candidateId:candidate,privacyRequestId:requestId,mode,retentionDays});
  try{
    const hold=await activeLegalHold(agency,candidate);
    if(hold){
      if(requestId)await updateRows('candidate_privacy_requests',{id:`eq.${requestId}`,agency_id:`eq.${agency}`},{status:'ON_HOLD',result_summary:{legal_hold_id:hold.id}});
      await finishRun(runId,{status:'SKIPPED_LEGAL_HOLD',evidence:{legal_hold_id:hold.id,reason:hold.reason}});
      return {ok:false,blocked:true,reason:'legal_hold',runId,hold};
    }

    const [candidateRows,documents,attachments,applications]=await Promise.all([
      serviceRequest(queryPath('candidates',{select:'id,profile_photo_path,retention_status,archived_at',agency_id:`eq.${agency}`,id:`eq.${candidate}`,limit:'1'})),
      serviceRequest(queryPath('candidate_documents',{select:'id,storage_path,filename',agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`})),
      serviceRequest(queryPath('recruitment_attachments',{select:'id,storage_path,filename',agency_id:`eq.${agency}`,entity_type:'eq.CANDIDATE',entity_id:`eq.${candidate}`})),
      serviceRequest(queryPath('applications',{select:'id',agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`}))
    ]);
    const row=Array.isArray(candidateRows)?candidateRows[0]:null;
    if(!row){await finishRun(runId,{status:'ERROR',error_code:'candidate_not_found'});return {ok:false,error:'candidate_not_found',runId}}
    const objectPaths=[row.profile_photo_path,...(documents||[]).map(x=>x.storage_path),...(attachments||[]).map(x=>x.storage_path)].filter(Boolean);
    const applicationIds=(applications||[]).map(x=>x.id).filter(Boolean);
    const appFilter=idFilter(applicationIds,'application_id');
    const plan={candidate_id:candidate,private_objects:objectPaths.length,applications:applicationIds.length,mode};
    if(!execute){
      await finishRun(runId,{status:'COMPLETED',evidence:{dry_run:true,plan}});
      return {ok:true,dryRun:true,runId,plan};
    }

    if(requestId)await updateRows('candidate_privacy_requests',{id:`eq.${requestId}`,agency_id:`eq.${agency}`},{status:'IN_PROGRESS',handled_by_user_id:null,updated_at:iso()});

    let removed=0,scrubbed=0;
    for(const path of objectPaths){await storageDelete(path);removed++}

    if(Array.isArray(documents)&&documents.length){
      await updateRows('candidate_documents',{agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`},{filename:'deleted-by-privacy-policy',mime_type:null,size_bytes:null,checksum:null,is_primary:false,archived_at:iso()});scrubbed+=documents.length;
    }
    if(Array.isArray(attachments)&&attachments.length){
      await updateRows('recruitment_attachments',{agency_id:`eq.${agency}`,entity_type:'eq.CANDIDATE',entity_id:`eq.${candidate}`},{filename:'deleted-by-privacy-policy',mime_type:null,size_bytes:null,archived_at:iso()});scrubbed+=attachments.length;
    }

    await updateRows('candidate_parse_runs',{agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`},{extracted_data:{},field_confidence:{},field_evidence:{},error_message:null});scrubbed++;
    await updateRows('candidate_profile_versions',{agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`},{profile_json:{}});scrubbed++;
    await deleteRows('candidate_profile_skills',{agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`});scrubbed++;
    await updateRows('candidate_fact_assertions',{agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`},{fact_value:null,evidence:'[deleted by privacy policy]'});scrubbed++;

    if(appFilter){
      await updateRows('application_screening_sessions',{agency_id:`eq.${agency}`,application_id:appFilter},{candidate_snapshot:{},intelligence_snapshot:{},recruiter_notes:null,open_questions:[],hard_rule_issues:[]});scrubbed++;
      await updateRows('application_screening_answers',{agency_id:`eq.${agency}`,application_id:appFilter},{answer:null,reason:null,source_evidence:[],ai_metadata:{}});scrubbed++;
      await updateRows('candidate_submissions',{agency_id:`eq.${agency}`,application_id:appFilter},{summary:null,salary_expectation:null,salary_currency:null,availability:null,notice_period_days:null,document_ids:[]});scrubbed++;
      await updateRows('candidate_submission_versions',{agency_id:`eq.${agency}`,application_id:appFilter},{candidate_snapshot:{},screening_snapshot:{},submission_pack:{},client_facing_pack:{},provenance_map:{},internal_commercial_snapshot:{},client_commercial_snapshot:{},eligibility_snapshot:{},change_summary:{},resume_checksum:null});scrubbed++;
      await updateRows('candidate_submission_reviews',{agency_id:`eq.${agency}`,application_id:appFilter},{note:null,checklist_snapshot:{}});scrubbed++;
    }

    const stamp=iso();
    await updateRows('candidate_portal_sessions',{agency_id:`eq.${agency}`,candidate_id:`eq.${candidate}`,revoked_at:'is.null'},{revoked_at:stamp});
    await updateRows('candidates',{agency_id:`eq.${agency}`,id:`eq.${candidate}`},{
      full_name:`Deleted candidate ${candidate.slice(0,8)}`,preferred_name:null,headline:null,
      email:null,secondary_email:null,phone:null,secondary_phone:null,location:null,city:null,region:null,
      current_title:null,current_company:null,resume_text:null,profile_photo_path:null,
      salary_current:null,salary_expected:null,notice_period_days:null,
      skills:[],education:[],certifications:[],languages:[],desired_locations:[],work_authorization_summary:[],tags:[],
      consent_status:'WITHDRAWN',consent_source:'PRIVACY_DELETION',consent_at:stamp,
      retention_status:'DELETED',dedupe_key:`deleted:${candidate}`,archived_at:stamp,updated_at:stamp
    });scrubbed++;

    if(requestId)await updateRows('candidate_privacy_requests',{id:`eq.${requestId}`,agency_id:`eq.${agency}`},{status:'COMPLETED',completed_at:stamp,updated_at:stamp,result_summary:{run_id:runId,storage_objects_removed:removed,database_records_scrubbed:scrubbed,method:'ANONYMIZE_AND_DESTROY_PRIVATE_OBJECTS'}});
    await audit({agencyId:agency,candidateId:candidate,action:'privacy.candidate_deleted',metadata:{run_id:runId,privacy_request_id:requestId,storage_objects_removed:removed,database_records_scrubbed:scrubbed,method:'ANONYMIZE_AND_DESTROY_PRIVATE_OBJECTS'}});
    await finishRun(runId,{status:'COMPLETED',storage_objects_removed:removed,database_records_scrubbed:scrubbed,evidence:{plan,method:'ANONYMIZE_AND_DESTROY_PRIVATE_OBJECTS',candidate_token:hash(candidate).slice(0,16)}});
    return {ok:true,dryRun:false,runId,storageObjectsRemoved:removed,databaseRecordsScrubbed:scrubbed};
  }catch(error){
    await finishRun(runId,{status:'ERROR',error_code:String(error?.message||'retention_error').slice(0,120),evidence:{failed_at:iso()}}).catch(()=>null);
    if(requestId)await updateRows('candidate_privacy_requests',{id:`eq.${requestId}`,agency_id:`eq.${agency}`},{status:'ERROR',updated_at:iso(),result_summary:{run_id:runId,error_code:String(error?.message||'retention_error').slice(0,120)}}).catch(()=>null);
    throw error;
  }
}

export async function findRetentionCandidates({limit=100}={}){
  const governance=await serviceRequest(queryPath('organization_data_governance',{select:'agency_id,candidate_retention_days',limit:'5000'}));
  const candidates=[];
  for(const policy of Array.isArray(governance)?governance:[]){
    const days=Math.max(30,Math.min(Number(policy.candidate_retention_days)||2555,3650));
    const cutoff=new Date(Date.now()-days*24*60*60*1000).toISOString();
    const rows=await serviceRequest(queryPath('candidates',{select:'id,agency_id,archived_at,updated_at,retention_status',agency_id:`eq.${policy.agency_id}`,archived_at:'not.is.null',retention_status:'neq.DELETED',updated_at:`lt.${cutoff}`,order:'updated_at.asc',limit:String(Math.max(1,Math.min(Number(limit)||100,500)))}));
    for(const row of Array.isArray(rows)?rows:[])candidates.push({...row,retention_days:days,cutoff});
    if(candidates.length>=limit)break;
  }
  return candidates.slice(0,limit);
}
