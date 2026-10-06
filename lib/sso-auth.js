import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { SUPABASE_URL } from '@/lib/supabase-api';

const SERVICE_KEY=String(process.env.SUPABASE_SERVICE_ROLE_KEY||'').trim();
const SESSION_HOURS=Math.max(1,Math.min(Number(process.env.XZRECRUITER_SSO_SESSION_HOURS||8),12));

function configured(){
  return /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(String(SUPABASE_URL||''))&&Boolean(SERVICE_KEY);
}
async function serviceRequest(path,{method='GET',body,prefer}={}){
  if(!configured())throw new Error('sso_session_bridge_not_configured');
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
    const error=new Error('sso_session_bridge_request_failed');
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
function normalizedEmail(value){
  const email=String(value||'').trim().toLowerCase();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))throw new Error('sso_email_missing');
  return email;
}

export async function createWorkspaceSessionFromSso({email,authUserId,providerId}){
  const normalized=normalizedEmail(email);
  const users=await serviceRequest(queryPath('users',{
    select:'id,email,disabled_at',
    email:`eq.${normalized}`,
    limit:'2'
  }));
  const active=(Array.isArray(users)?users:[]).filter(user=>!user.disabled_at);
  if(active.length!==1)throw new Error(active.length===0?'sso_user_not_provisioned':'sso_user_ambiguous');
  const user=active[0];

  const memberships=await serviceRequest(queryPath('agency_memberships',{
    select:'agency_id,role,active,created_at',
    user_id:`eq.${user.id}`,
    active:'eq.true',
    order:'created_at.asc',
    limit:'2'
  }));
  const allowed=Array.isArray(memberships)?memberships:[];
  if(allowed.length===0)throw new Error('sso_workspace_missing');
  if(allowed.length>1)throw new Error('sso_workspace_selection_required');
  const membership=allowed[0];

  const rawToken=randomBytes(32).toString('hex');
  const tokenHash=createHash('sha256').update(rawToken).digest('hex');
  const sessionId=randomUUID();
  const expiresAt=new Date(Date.now()+SESSION_HOURS*60*60*1000).toISOString();
  await serviceRequest('/rest/v1/user_sessions',{
    method:'POST',
    body:{
      id:sessionId,
      user_id:user.id,
      agency_id:membership.agency_id,
      token_hash:tokenHash,
      expires_at:expiresAt
    },
    prefer:'return=minimal'
  });
  await serviceRequest('/rest/v1/audit_events',{
    method:'POST',
    body:{
      id:randomUUID(),
      agency_id:membership.agency_id,
      actor_user_id:user.id,
      action:'auth.sso_login',
      entity_type:'user',
      entity_id:user.id,
      metadata:{
        session_id:sessionId,
        auth_user_id:String(authUserId||'').slice(0,80)||null,
        sso_provider_id:String(providerId||'').slice(0,80)||null,
        session_hours:SESSION_HOURS
      }
    },
    prefer:'return=minimal'
  });
  return {token:rawToken,sessionId,agencyId:membership.agency_id,userId:user.id,role:membership.role,expiresAt};
}
