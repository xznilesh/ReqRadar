import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { assertUuid, queryPath, serviceRequest } from '../service-store.js';

function hash(value){return createHash('sha256').update(String(value||'')).digest('hex')}
function normalizeScopes(scopes){
  const values=Array.isArray(scopes)?scopes:[];
  const clean=[...new Set(values.map(v=>String(v||'').trim().toLowerCase()).filter(v=>/^[a-z][a-z0-9_-]{1,40}:[a-z][a-z0-9_-]{1,40}$/.test(v)))];
  if(clean.length>50)throw new Error('too_many_api_key_scopes');
  return clean;
}
async function audit({agencyId,userId,action,entityId,metadata={}}){
  await serviceRequest('/rest/v1/audit_events',{
    method:'POST',body:{id:randomUUID(),agency_id:agencyId,actor_user_id:userId,action,entity_type:'api_key',entity_id:entityId,metadata},
    prefer:'return=minimal'
  });
}

export async function createApiKey({agencyId,userId,name,scopes=[],expiresAt=null}){
  const agency=assertUuid(agencyId,'agency_id'),actor=assertUuid(userId,'user_id');
  const secret='xzr_live_'+randomBytes(32).toString('base64url');
  const id=randomUUID(), prefix=secret.slice(0,16);
  const row={id,agency_id:agency,key_prefix:prefix,key_hash:hash(secret),name:String(name||'API key').trim().slice(0,120)||'API key',scopes:normalizeScopes(scopes),active:true,expires_at:expiresAt||null,created_by_user_id:actor};
  await serviceRequest('/rest/v1/enterprise_api_keys',{method:'POST',body:row,prefer:'return=minimal'});
  await audit({agencyId:agency,userId:actor,action:'integration.api_key_created',entityId:id,metadata:{prefix,scopes:row.scopes}});
  return {id,key:secret,prefix,name:row.name,scopes:row.scopes,expiresAt:row.expires_at};
}

export async function listApiKeys({agencyId}){
  const agency=assertUuid(agencyId,'agency_id');
  const rows=await serviceRequest(queryPath('enterprise_api_keys',{select:'id,key_prefix,name,scopes,active,expires_at,last_used_at,revoked_at,created_at,updated_at',agency_id:`eq.${agency}`,order:'created_at.desc',limit:'200'}));
  return Array.isArray(rows)?rows:[];
}

export async function verifyApiKey(raw,{requiredScope=null}={}){
  const token=String(raw||'').trim();
  if(!token.startsWith('xzr_live_')||token.length<32)throw new Error('api_key_invalid');
  const rows=await serviceRequest(queryPath('enterprise_api_keys',{select:'id,agency_id,key_prefix,name,scopes,active,expires_at,revoked_at',key_hash:`eq.${hash(token)}`,active:'eq.true',revoked_at:'is.null',limit:'1'}));
  const row=Array.isArray(rows)?rows[0]:null;
  if(!row)throw new Error('api_key_invalid');
  if(row.expires_at&&Date.parse(row.expires_at)<=Date.now())throw new Error('api_key_expired');
  const scopes=Array.isArray(row.scopes)?row.scopes:[];
  if(requiredScope&&!scopes.includes(requiredScope)&&!scopes.includes('*:*'))throw new Error('api_key_scope_denied');
  await serviceRequest(queryPath('enterprise_api_keys',{id:`eq.${row.id}`}),{method:'PATCH',body:{last_used_at:new Date().toISOString(),updated_at:new Date().toISOString()},prefer:'return=minimal'}).catch(()=>null);
  return {id:row.id,agencyId:row.agency_id,prefix:row.key_prefix,name:row.name,scopes};
}

export async function revokeApiKey({agencyId,userId,keyId}){
  const agency=assertUuid(agencyId,'agency_id'),actor=assertUuid(userId,'user_id'),id=assertUuid(keyId,'api_key_id');
  const stamp=new Date().toISOString();
  const rows=await serviceRequest(queryPath('enterprise_api_keys',{select:'id',agency_id:`eq.${agency}`,id:`eq.${id}`,revoked_at:'is.null'}),{method:'PATCH',body:{active:false,revoked_at:stamp,revoked_by_user_id:actor,updated_at:stamp},prefer:'return=representation'});
  if(!Array.isArray(rows)||!rows[0])return {ok:false,error:'not_found'};
  await audit({agencyId:agency,userId:actor,action:'integration.api_key_revoked',entityId:id});
  return {ok:true,id};
}

export async function rotateApiKey({agencyId,userId,keyId}){
  const agency=assertUuid(agencyId,'agency_id'),actor=assertUuid(userId,'user_id'),id=assertUuid(keyId,'api_key_id');
  const rows=await serviceRequest(queryPath('enterprise_api_keys',{select:'id,name,scopes,expires_at',agency_id:`eq.${agency}`,id:`eq.${id}`,active:'eq.true',revoked_at:'is.null',limit:'1'}));
  const old=Array.isArray(rows)?rows[0]:null;
  if(!old)throw new Error('api_key_not_found');
  const created=await createApiKey({agencyId:agency,userId:actor,name:old.name,scopes:old.scopes,expiresAt:old.expires_at});
  await revokeApiKey({agencyId:agency,userId:actor,keyId:id});
  await audit({agencyId:agency,userId:actor,action:'integration.api_key_rotated',entityId:created.id,metadata:{previous_key_id:id}});
  return created;
}
