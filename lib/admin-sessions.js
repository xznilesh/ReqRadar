import { createHash, randomUUID } from 'node:crypto';
import { SUPABASE_URL } from '@/lib/supabase-api';

const SERVICE_KEY=String(process.env.SUPABASE_SERVICE_ROLE_KEY||'').trim();

export function adminSessionStoreConfigured(){
  return /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(String(SUPABASE_URL||''))&&Boolean(SERVICE_KEY);
}

function assertUuid(value,label='id'){
  const v=String(value||'');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v))throw new Error('invalid_'+label);
  return v;
}

async function serviceRequest(path,{method='GET',body,prefer}={}){
  if(!adminSessionStoreConfigured())throw new Error('admin_session_store_not_configured');
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
    const error=new Error('admin_session_store_request_failed');
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

export async function currentWorkspaceSessionId({agencyId,token}){
  const agency=assertUuid(agencyId,'agency_id');
  const raw=String(token||'');
  if(!raw)return null;
  const tokenHash=createHash('sha256').update(raw).digest('hex');
  const rows=await serviceRequest(queryPath('user_sessions',{
    select:'id',
    agency_id:`eq.${agency}`,
    token_hash:`eq.${tokenHash}`,
    revoked_at:'is.null',
    limit:'1'
  }));
  return Array.isArray(rows)&&rows[0]?.id?rows[0].id:null;
}

export async function listWorkspaceSessions({agencyId,currentSessionId=null,limit=200}){
  const agency=assertUuid(agencyId,'agency_id');
  const safeLimit=Math.max(1,Math.min(Number(limit||200),500));
  const sessions=await serviceRequest(queryPath('user_sessions',{
    select:'id,user_id,agency_id,expires_at,revoked_at',
    agency_id:`eq.${agency}`,
    order:'expires_at.desc',
    limit:String(safeLimit)
  }));
  const rows=Array.isArray(sessions)?sessions:[];
  const userIds=[...new Set(rows.map(row=>row.user_id).filter(Boolean))];
  let users=[];
  if(userIds.length){
    users=await serviceRequest(queryPath('users',{
      select:'id,email,display_name,disabled_at',
      id:`in.(${userIds.map(id=>assertUuid(id,'user_id')).join(',')})`
    }));
  }
  const byUser=new Map((Array.isArray(users)?users:[]).map(user=>[user.id,user]));
  return rows.map(row=>{
    const user=byUser.get(row.user_id)||{};
    return {
      id:row.id,
      user_id:row.user_id,
      user_email:user.email||null,
      user_display_name:user.display_name||null,
      user_disabled:Boolean(user.disabled_at),
      expires_at:row.expires_at||null,
      revoked_at:row.revoked_at||null,
      active:!row.revoked_at&&(!row.expires_at||Date.parse(row.expires_at)>Date.now()),
      current:currentSessionId===row.id
    };
  });
}

export async function revokeWorkspaceSession({agencyId,sessionId,actorUserId}){
  const agency=assertUuid(agencyId,'agency_id');
  const session=assertUuid(sessionId,'session_id');
  const actor=assertUuid(actorUserId,'actor_user_id');
  const now=new Date().toISOString();
  const updated=await serviceRequest(queryPath('user_sessions',{
    select:'id,user_id,agency_id,revoked_at',
    agency_id:`eq.${agency}`,
    id:`eq.${session}`,
    revoked_at:'is.null'
  }),{
    method:'PATCH',
    body:{revoked_at:now},
    prefer:'return=representation'
  });
  const target=Array.isArray(updated)?updated[0]:null;
  if(!target)return {ok:false,error:'session_not_found_or_already_revoked'};

  await serviceRequest('/rest/v1/audit_events',{
    method:'POST',
    body:{
      id:randomUUID(),
      agency_id:agency,
      actor_user_id:actor,
      action:'auth.session_revoked',
      entity_type:'session',
      entity_id:session,
      metadata:{target_user_id:target.user_id,revoked_at:now}
    },
    prefer:'return=minimal'
  });
  return {ok:true,session_id:session,target_user_id:target.user_id,revoked_at:now};
}
