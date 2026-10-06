import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { assertUuid, queryPath, serviceRequest, serviceStoreConfigured } from './service-store.js';

const SCIM_SCHEMA='urn:ietf:params:scim:schemas:core:2.0:User';
const SCIM_LIST='urn:ietf:params:scim:api:messages:2.0:ListResponse';
const SAFE_ROLES=new Set(['RECRUITER','VIEWER','MEMBER']);

function hash(value){return createHash('sha256').update(String(value||'')).digest('hex')}
function email(value){
  const normalized=String(value||'').trim().toLowerCase();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized))throw new Error('invalid_scim_email');
  return normalized;
}
function text(value,max=160){return String(value||'').trim().slice(0,max)}
function bearer(request){
  const header=String(request?.headers?.get?.('authorization')||'');
  const match=header.match(/^Bearer\s+(.+)$/i);
  return match?match[1].trim():'';
}
function userResource(user,membership){
  return {
    schemas:[SCIM_SCHEMA],
    id:user.id,
    userName:user.email,
    displayName:user.display_name||user.email,
    name:{formatted:user.display_name||user.email},
    active:membership?.active!==false,
    meta:{resourceType:'User'}
  };
}
async function audit({agencyId,actorUserId=null,action,userId,metadata={}}){
  await serviceRequest('/rest/v1/audit_events',{
    method:'POST',
    body:{
      id:randomUUID(),
      agency_id:agencyId,
      actor_user_id:actorUserId,
      action,
      entity_type:'user',
      entity_id:userId,
      metadata:{...metadata,provisioning_protocol:'SCIM'}
    },
    prefer:'return=minimal'
  });
}
async function membershipFor(agencyId,userId){
  const rows=await serviceRequest(queryPath('agency_memberships',{
    select:'agency_id,user_id,role,active,created_at',
    agency_id:`eq.${assertUuid(agencyId,'agency_id')}`,
    user_id:`eq.${assertUuid(userId,'user_id')}`,
    limit:'1'
  }));
  return Array.isArray(rows)?rows[0]||null:null;
}
async function userById(userId){
  const rows=await serviceRequest(queryPath('users',{
    select:'id,email,display_name,disabled_at',
    id:`eq.${assertUuid(userId,'user_id')}`,
    limit:'1'
  }));
  return Array.isArray(rows)?rows[0]||null:null;
}
async function userByEmail(rawEmail){
  const value=email(rawEmail);
  const rows=await serviceRequest(queryPath('users',{
    select:'id,email,display_name,disabled_at',
    email:`eq.${value}`,
    limit:'2'
  }));
  if(Array.isArray(rows)&&rows.length>1)throw new Error('scim_user_ambiguous');
  return Array.isArray(rows)?rows[0]||null:null;
}
async function assertSingleWorkspaceOrSameAgency(userId,agencyId){
  const rows=await serviceRequest(queryPath('agency_memberships',{
    select:'agency_id,active',
    user_id:`eq.${assertUuid(userId,'user_id')}`,
    active:'eq.true',
    limit:'2'
  }));
  const active=Array.isArray(rows)?rows:[];
  if(active.some(row=>row.agency_id!==agencyId))throw new Error('scim_user_workspace_conflict');
}

export function scimConfigured(){return serviceStoreConfigured()}

export async function authenticateScimRequest(request){
  const raw=bearer(request);
  if(!raw||raw.length<24)throw new Error('scim_unauthorized');
  const tokenHash=hash(raw);
  const rows=await serviceRequest(queryPath('enterprise_scim_tokens',{
    select:'id,agency_id,default_role,active,expires_at,revoked_at',
    token_hash:`eq.${tokenHash}`,
    active:'eq.true',
    revoked_at:'is.null',
    limit:'1'
  }));
  const record=Array.isArray(rows)?rows[0]:null;
  if(!record)throw new Error('scim_unauthorized');
  if(record.expires_at&&Date.parse(record.expires_at)<=Date.now())throw new Error('scim_unauthorized');
  const role=SAFE_ROLES.has(record.default_role)?record.default_role:'RECRUITER';
  await serviceRequest(queryPath('enterprise_scim_tokens',{id:`eq.${record.id}`}),{
    method:'PATCH',
    body:{last_used_at:new Date().toISOString(),updated_at:new Date().toISOString()},
    prefer:'return=minimal'
  }).catch(()=>null);
  return {tokenId:record.id,agencyId:record.agency_id,defaultRole:role};
}

export async function issueScimToken({agencyId,actorUserId,label='SCIM',defaultRole='RECRUITER',expiresAt=null}){
  const agency=assertUuid(agencyId,'agency_id');
  const actor=assertUuid(actorUserId,'actor_user_id');
  const role=SAFE_ROLES.has(String(defaultRole||'').toUpperCase())?String(defaultRole).toUpperCase():'RECRUITER';
  const secret='xzr_scim_'+randomBytes(32).toString('base64url');
  const id=randomUUID();
  await serviceRequest('/rest/v1/enterprise_scim_tokens',{
    method:'POST',
    body:{
      id,agency_id:agency,token_hash:hash(secret),token_prefix:secret.slice(0,16),
      label:text(label,80)||'SCIM',default_role:role,active:true,
      expires_at:expiresAt||null,created_by_user_id:actor
    },
    prefer:'return=minimal'
  });
  await audit({agencyId:agency,actorUserId:actor,action:'scim.token_created',userId:actor,metadata:{scim_token_id:id,default_role:role}});
  return {id,token:secret,prefix:secret.slice(0,16),defaultRole:role,expiresAt:expiresAt||null};
}

export async function revokeScimToken({agencyId,actorUserId,tokenId}){
  const agency=assertUuid(agencyId,'agency_id');
  const actor=assertUuid(actorUserId,'actor_user_id');
  const id=assertUuid(tokenId,'scim_token_id');
  const now=new Date().toISOString();
  const rows=await serviceRequest(queryPath('enterprise_scim_tokens',{
    select:'id',
    id:`eq.${id}`,agency_id:`eq.${agency}`,revoked_at:'is.null'
  }),{
    method:'PATCH',
    body:{active:false,revoked_at:now,revoked_by_user_id:actor,updated_at:now},
    prefer:'return=representation'
  });
  if(!Array.isArray(rows)||!rows[0])return {ok:false,error:'not_found'};
  await audit({agencyId:agency,actorUserId:actor,action:'scim.token_revoked',userId:actor,metadata:{scim_token_id:id}});
  return {ok:true,id};
}

export async function listScimUsers({agencyId,filter='',startIndex=1,count=100}){
  const agency=assertUuid(agencyId,'agency_id');
  const memberships=await serviceRequest(queryPath('agency_memberships',{
    select:'agency_id,user_id,role,active,created_at',
    agency_id:`eq.${agency}`,
    order:'created_at.asc',
    limit:'500'
  }));
  let memberRows=Array.isArray(memberships)?memberships:[];
  const match=String(filter||'').match(/^userName\s+eq\s+["']([^"']+)["']$/i);
  let requestedEmail=null;
  if(filter&& !match)throw new Error('unsupported_scim_filter');
  if(match)requestedEmail=email(match[1]);

  const ids=memberRows.map(row=>row.user_id).filter(Boolean);
  let users=[];
  if(ids.length){
    users=await serviceRequest(queryPath('users',{
      select:'id,email,display_name,disabled_at',
      id:`in.(${ids.map(id=>assertUuid(id,'user_id')).join(',')})`
    }));
  }
  const byId=new Map((Array.isArray(users)?users:[]).map(row=>[row.id,row]));
  let resources=memberRows.map(m=>byId.get(m.user_id)?userResource(byId.get(m.user_id),m):null).filter(Boolean);
  if(requestedEmail)resources=resources.filter(resource=>resource.userName===requestedEmail);
  const totalResults=resources.length;
  const start=Math.max(1,Number(startIndex)||1);
  const size=Math.max(1,Math.min(Number(count)||100,200));
  resources=resources.slice(start-1,start-1+size);
  return {schemas:[SCIM_LIST],totalResults,startIndex:start,itemsPerPage:resources.length,Resources:resources};
}

export async function getScimUser({agencyId,userId}){
  const user=await userById(userId);
  if(!user)return null;
  const membership=await membershipFor(agencyId,user.id);
  return membership?userResource(user,membership):null;
}

export async function createScimUser({agencyId,defaultRole,payload}){
  const agency=assertUuid(agencyId,'agency_id');
  const username=email(payload?.userName);
  const displayName=text(payload?.displayName||payload?.name?.formatted||username,160)||username;
  let user=await userByEmail(username);
  if(user){
    await assertSingleWorkspaceOrSameAgency(user.id,agency);
    const existing=await membershipFor(agency,user.id);
    if(existing&&existing.active!==false)throw new Error('scim_user_exists');
  }else{
    const id=randomUUID();
    const now=new Date().toISOString();
    await serviceRequest('/rest/v1/users',{
      method:'POST',
      body:{id,email:username,display_name:displayName,email_verified_at:now},
      prefer:'return=minimal'
    });
    user={id,email:username,display_name:displayName,disabled_at:null};
  }

  const role=SAFE_ROLES.has(defaultRole)?defaultRole:'RECRUITER';
  const existing=await membershipFor(agency,user.id);
  if(existing){
    await serviceRequest(queryPath('agency_memberships',{agency_id:`eq.${agency}`,user_id:`eq.${user.id}`}),{
      method:'PATCH',body:{active:payload?.active!==false,role},prefer:'return=minimal'
    });
  }else{
    await serviceRequest('/rest/v1/agency_memberships',{
      method:'POST',
      body:{agency_id:agency,user_id:user.id,role,active:payload?.active!==false},
      prefer:'return=minimal'
    });
  }
  if(displayName!==user.display_name){
    await serviceRequest(queryPath('users',{id:`eq.${user.id}`}),{method:'PATCH',body:{display_name:displayName},prefer:'return=minimal'});
    user.display_name=displayName;
  }
  await audit({agencyId:agency,action:'scim.user_provisioned',userId:user.id,metadata:{active:payload?.active!==false,role}});
  return userResource(user,{active:payload?.active!==false,role});
}

export async function patchScimUser({agencyId,userId,payload}){
  const agency=assertUuid(agencyId,'agency_id');
  const id=assertUuid(userId,'user_id');
  const user=await userById(id);
  const membership=await membershipFor(agency,id);
  if(!user||!membership)return null;

  let active=membership.active!==false;
  let displayName=user.display_name||user.email;
  const operations=Array.isArray(payload?.Operations)?payload.Operations:[];
  for(const operation of operations){
    const op=String(operation?.op||'').toLowerCase();
    if(!['replace','add'].includes(op))continue;
    const path=String(operation?.path||'').toLowerCase();
    if(path==='active')active=operation.value!==false&&String(operation.value).toLowerCase()!=='false';
    else if(path==='displayname'||path==='name.formatted')displayName=text(operation.value,160)||displayName;
    else if(!path&&operation?.value&&typeof operation.value==='object'){
      if('active' in operation.value)active=operation.value.active!==false;
      if(operation.value.displayName)displayName=text(operation.value.displayName,160)||displayName;
    }
  }
  if('active' in (payload||{}))active=payload.active!==false;
  if(payload?.displayName)displayName=text(payload.displayName,160)||displayName;

  await serviceRequest(queryPath('agency_memberships',{agency_id:`eq.${agency}`,user_id:`eq.${id}`}),{
    method:'PATCH',body:{active},prefer:'return=minimal'
  });
  if(displayName!==user.display_name){
    await serviceRequest(queryPath('users',{id:`eq.${id}`}),{method:'PATCH',body:{display_name:displayName},prefer:'return=minimal'});
    user.display_name=displayName;
  }
  await audit({agencyId:agency,action:active?'scim.user_updated':'scim.user_deactivated',userId:id,metadata:{active}});
  return userResource(user,{...membership,active});
}

export async function deactivateScimUser({agencyId,userId}){
  return patchScimUser({agencyId,userId,payload:{active:false}});
}

export function scimError(error,status=400){
  const message=String(error?.message||error||'scim_error');
  const mapped=message==='scim_unauthorized'?401:
    message==='scim_user_exists'||message==='scim_user_workspace_conflict'?409:
    message==='unsupported_scim_filter'?400:status;
  return {
    status:mapped,
    body:{schemas:['urn:ietf:params:scim:api:messages:2.0:Error'],status:String(mapped),detail:message}
  };
}
