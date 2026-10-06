import { randomUUID } from 'node:crypto';
import { SUPABASE_URL } from '@/lib/supabase-api';

const SERVICE_KEY=String(process.env.SUPABASE_SERVICE_ROLE_KEY||'').trim();

function configured(){
  return /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(String(SUPABASE_URL||''))&&Boolean(SERVICE_KEY);
}
function uuid(value,label='id'){
  const v=String(value||'');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v))throw new Error('invalid_'+label);
  return v;
}
async function serviceRequest(path,{method='GET',body,prefer}={}){
  if(!configured())throw new Error('compliance_store_not_configured');
  const response=await fetch(SUPABASE_URL+path,{
    method,
    headers:{
      apikey:SERVICE_KEY,
      authorization:`Bearer ${SERVICE_KEY}`,
      accept:'application/json',
      ...(body!==undefined?{'content-type':'application/json'}:{}),
      ...(prefer?{prefer}:{})
    },
    ...(body!==undefined?{body:JSON.stringify(body)}:{}),
    cache:'no-store'
  });
  const text=await response.text();
  let data=null;
  if(text){try{data=JSON.parse(text)}catch{data=text}}
  if(!response.ok){
    const error=new Error('compliance_store_request_failed');
    error.status=response.status;
    error.details=data;
    throw error;
  }
  return data;
}
function queryPath(table,params){
  const q=new URLSearchParams();
  for(const [key,value] of Object.entries(params||{}))if(value!==undefined&&value!==null)q.set(key,String(value));
  return `/rest/v1/${table}?${q.toString()}`;
}
function normalizedStatus(value){return String(value||'UNKNOWN').trim().toUpperCase()||'UNKNOWN'}
function normalizedSource(value){const v=String(value||'').trim();return v||null}

export async function recordConsentChange({agencyId,actorUserId,candidateId,before,after}){
  const agency=uuid(agencyId,'agency_id');
  const actor=uuid(actorUserId,'actor_user_id');
  const candidate=uuid(candidateId,'candidate_id');
  const previous={status:normalizedStatus(before?.status),source:normalizedSource(before?.source)};
  const next={status:normalizedStatus(after?.status),source:normalizedSource(after?.source)};
  if(previous.status===next.status&&previous.source===next.source)return {recorded:false};

  await serviceRequest('/rest/v1/audit_events',{
    method:'POST',
    body:{
      id:randomUUID(),
      agency_id:agency,
      actor_user_id:actor,
      action:'candidate.consent_changed',
      entity_type:'candidate',
      entity_id:candidate,
      metadata:{
        previous_status:previous.status,
        previous_source:previous.source,
        status:next.status,
        source:next.source
      }
    },
    prefer:'return=minimal'
  });
  return {recorded:true};
}

export async function candidateConsentHistory({agencyId,candidateId}){
  const agency=uuid(agencyId,'agency_id');
  const candidate=uuid(candidateId,'candidate_id');
  const [candidateRows,applications,auditEvents]=await Promise.all([
    serviceRequest(queryPath('candidates',{
      select:'id,consent_status,consent_source,consent_at,retention_status',
      agency_id:`eq.${agency}`,
      id:`eq.${candidate}`,
      limit:'1'
    })),
    serviceRequest(queryPath('applications',{
      select:'id,job_id,created_at,metadata',
      agency_id:`eq.${agency}`,
      candidate_id:`eq.${candidate}`,
      order:'created_at.asc'
    })),
    serviceRequest(queryPath('audit_events',{
      select:'id,actor_user_id,action,metadata,created_at',
      agency_id:`eq.${agency}`,
      entity_type:'eq.candidate',
      entity_id:`eq.${candidate}`,
      action:'in.(candidate.consent_changed,candidate.consent_history)',
      order:'created_at.asc'
    }))
  ]);

  const events=[];
  for(const application of Array.isArray(applications)?applications:[]){
    const consentAt=application?.metadata?.consent_at;
    if(!consentAt)continue;
    events.push({
      event:'CONSENT_GRANTED',
      source:'PUBLIC_APPLICATION',
      occurred_at:consentAt,
      application_id:application.id,
      job_id:application.job_id,
      actor_user_id:null
    });
  }
  for(const event of Array.isArray(auditEvents)?auditEvents:[]){
    const transactional=event.action==='candidate.consent_history'&&event?.metadata?.transactional===true;
    const current=transactional?event?.metadata?.current||{}:event?.metadata||{};
    const previous=transactional?event?.metadata?.previous||{}:event?.metadata||{};
    events.push({
      event:'CONSENT_CHANGED',
      source:current?.source||null,
      status:current?.status||'UNKNOWN',
      previous_status:previous?.status||previous?.previous_status||'UNKNOWN',
      previous_source:previous?.source||previous?.previous_source||null,
      consent_at:current?.consent_at||null,
      occurred_at:event.created_at,
      application_id:null,
      job_id:null,
      actor_user_id:event.actor_user_id||null,
      transactional
    });
  }
  events.sort((a,b)=>Date.parse(a.occurred_at||0)-Date.parse(b.occurred_at||0));
  const current=Array.isArray(candidateRows)?candidateRows[0]:null;
  const audited=Array.isArray(auditEvents)?auditEvents:[];
  const transactionalAudits=audited.filter(event=>event.action==='candidate.consent_history'&&event?.metadata?.transactional===true);
  const historyCertified=transactionalAudits.length>0&&audited.every(event=>event.action==='candidate.consent_history'&&event?.metadata?.transactional===true);
  return {
    current:current?{
      status:normalizedStatus(current.consent_status),
      source:normalizedSource(current.consent_source),
      consent_at:current.consent_at||null,
      retention_status:current.retention_status||'ACTIVE'
    }:null,
    events,
    history_available:true,
    history_certified:historyCertified===true,
    certification_basis:historyCertified?'transactional_database_trigger':'legacy_or_unverified_history',
    scope_note:historyCertified
      ?'Consent mutations are backed by the transactional candidate consent-history database trigger; public-application consent timestamps are also included.'
      :'Legacy or pre-trigger consent history is present. history_certified:true is returned only after transactional database-trigger evidence exists and all audited consent mutations use that path.'
  };
}


function inIds(ids,label='id'){
  const clean=[...new Set((ids||[]).filter(Boolean).map(value=>uuid(value,label)))];
  return clean.length?`in.(${clean.join(',')})`:null;
}
async function scopedRows(table,agency,params={}){
  const rows=await serviceRequest(queryPath(table,{select:'*',agency_id:`eq.${agency}`,...params}));
  return Array.isArray(rows)?rows:[];
}

export async function candidateDataSubjectAccess({agencyId,candidateId}){
  const agency=uuid(agencyId,'agency_id');
  const candidate=uuid(candidateId,'candidate_id');
  const [
    candidateRows,
    applications,
    documents,
    parseRuns,
    profileVersions,
    factAssertions,
    intelligenceJobs,
    matchRuns
  ]=await Promise.all([
    scopedRows('candidates',agency,{id:`eq.${candidate}`,limit:'1'}),
    scopedRows('applications',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'}),
    scopedRows('candidate_documents',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'}),
    scopedRows('candidate_parse_runs',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'}),
    scopedRows('candidate_profile_versions',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'}),
    scopedRows('candidate_fact_assertions',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'}),
    scopedRows('candidate_intelligence_jobs',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'}),
    scopedRows('candidate_match_runs',agency,{candidate_id:`eq.${candidate}`,order:'created_at.asc'})
  ]);
  if(!candidateRows[0])return null;

  const applicationIds=applications.map(row=>row.id).filter(Boolean);
  const appFilter=inIds(applicationIds,'application_id');
  let screeningSessions=[],screeningSummaries=[],screeningOverrides=[],intelligenceReviews=[],submissions=[],interviews=[],offers=[],placements=[];
  if(appFilter){
    [screeningSessions,screeningSummaries,screeningOverrides,intelligenceReviews,submissions,interviews,offers,placements]=await Promise.all([
      scopedRows('application_screening_sessions',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('application_screening_summaries',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('application_screening_overrides',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('candidate_intelligence_reviews',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('candidate_submissions',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('interviews',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('offers',agency,{application_id:appFilter,order:'created_at.asc'}),
      scopedRows('placements',agency,{application_id:appFilter,order:'created_at.asc'})
    ]);
  }

  const screeningSessionIds=screeningSessions.map(row=>row.id).filter(Boolean);
  const submissionIds=submissions.map(row=>row.id).filter(Boolean);
  const screeningFilter=inIds(screeningSessionIds,'screening_session_id');
  const submissionFilter=inIds(submissionIds,'submission_id');
  const screeningAnswers=screeningFilter
    ?await scopedRows('application_screening_answers',agency,{screening_session_id:screeningFilter,order:'created_at.asc'})
    :[];
  const [submissionVersions,submissionReviews]=submissionFilter
    ?await Promise.all([
      scopedRows('candidate_submission_versions',agency,{submission_id:submissionFilter,order:'created_at.asc'}),
      scopedRows('candidate_submission_reviews',agency,{submission_id:submissionFilter,order:'created_at.asc'})
    ])
    :[[],[]];

  return {
    candidate:candidateRows[0],
    applications,
    documents:documents.map(({storage_path,...row})=>({...row,private_object_present:Boolean(storage_path)})),
    parse_runs:parseRuns,
    candidate_profile_versions:profileVersions,
    candidate_fact_assertions:factAssertions,
    candidate_intelligence_jobs:intelligenceJobs,
    candidate_match_runs:matchRuns,
    candidate_intelligence_reviews:intelligenceReviews,
    screening_sessions:screeningSessions,
    screening_answers:screeningAnswers,
    screening_summaries:screeningSummaries,
    screening_overrides:screeningOverrides,
    submissions,
    submission_versions:submissionVersions,
    submission_reviews:submissionReviews,
    interviews,
    offers,
    placements,
    scope:{
      database_subject_records:true,
      private_document_binary_embedded:false,
      third_party_processor_exports:false
    }
  };
}
