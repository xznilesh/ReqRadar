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
      action:'eq.candidate.consent_changed',
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
    events.push({
      event:'CONSENT_CHANGED',
      source:event?.metadata?.source||null,
      status:event?.metadata?.status||'UNKNOWN',
      previous_status:event?.metadata?.previous_status||'UNKNOWN',
      previous_source:event?.metadata?.previous_source||null,
      occurred_at:event.created_at,
      application_id:null,
      job_id:null,
      actor_user_id:event.actor_user_id||null
    });
  }
  events.sort((a,b)=>Date.parse(a.occurred_at||0)-Date.parse(b.occurred_at||0));
  const current=Array.isArray(candidateRows)?candidateRows[0]:null;
  return {
    current:current?{
      status:normalizedStatus(current.consent_status),
      source:normalizedSource(current.consent_source),
      consent_at:current.consent_at||null,
      retention_status:current.retention_status||'ACTIVE'
    }:null,
    events,
    history_available:true,
    scope_note:'Includes public-application consent timestamps and audited in-app consent changes from this implementation onward.'
  };
}
