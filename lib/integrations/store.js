import { randomUUID } from 'node:crypto';
import { assertUuid, queryPath, serviceRequest } from '../service-store.js';
import { decryptIntegrationSecret, encryptIntegrationSecret } from './crypto.js';

const PROVIDERS=new Set(['GOOGLE','MICROSOFT']);
function provider(value){const p=String(value||'').toUpperCase();if(!PROVIDERS.has(p))throw new Error('invalid_integration_provider');return p}
function now(){return new Date().toISOString()}

export async function getIntegrationConnection({agencyId,userId,provider:rawProvider}){
  const agency=assertUuid(agencyId,'agency_id'), user=assertUuid(userId,'user_id'), p=provider(rawProvider);
  const rows=await serviceRequest(queryPath('enterprise_integration_connections',{
    select:'id,agency_id,user_id,provider,external_account_id,external_account_email,access_token_ciphertext,refresh_token_ciphertext,token_expires_at,scopes,status,last_health_at,last_error_code,last_error_at,created_at,updated_at,revoked_at',
    agency_id:`eq.${agency}`,user_id:`eq.${user}`,provider:`eq.${p}`,limit:'1'
  }));
  const row=Array.isArray(rows)?rows[0]||null:null;
  if(!row)return null;
  return {
    ...row,
    accessToken:decryptIntegrationSecret(row.access_token_ciphertext,{agencyId:agency,userId:user,provider:p,kind:'access'}),
    refreshToken:decryptIntegrationSecret(row.refresh_token_ciphertext,{agencyId:agency,userId:user,provider:p,kind:'refresh'})
  };
}

export async function upsertIntegrationConnection({agencyId,userId,provider:rawProvider,externalAccountId=null,externalAccountEmail=null,accessToken=null,refreshToken=null,tokenExpiresAt=null,scopes=[],status='CONNECTED'}){
  const agency=assertUuid(agencyId,'agency_id'), user=assertUuid(userId,'user_id'), p=provider(rawProvider);
  const existing=await getIntegrationConnection({agencyId:agency,userId:user,provider:p}).catch(()=>null);
  const access=accessToken?encryptIntegrationSecret(accessToken,{agencyId:agency,userId:user,provider:p,kind:'access'}):existing?.access_token_ciphertext||null;
  const refresh=refreshToken?encryptIntegrationSecret(refreshToken,{agencyId:agency,userId:user,provider:p,kind:'refresh'}):existing?.refresh_token_ciphertext||null;
  const body={
    id:existing?.id||randomUUID(),
    agency_id:agency,user_id:user,provider:p,
    external_account_id:externalAccountId||existing?.external_account_id||null,
    external_account_email:externalAccountEmail||existing?.external_account_email||null,
    access_token_ciphertext:access,
    refresh_token_ciphertext:refresh,
    token_expires_at:tokenExpiresAt||existing?.token_expires_at||null,
    scopes:Array.isArray(scopes)?scopes:[],
    status,updated_at:now(),revoked_at:null
  };
  const rows=await serviceRequest('/rest/v1/enterprise_integration_connections?on_conflict=agency_id,user_id,provider',{
    method:'POST',body,prefer:'resolution=merge-duplicates,return=representation'
  });
  return Array.isArray(rows)?rows[0]||body:body;
}

export async function updateIntegrationHealth({agencyId,userId,provider:rawProvider,ok,errorCode=null}){
  const agency=assertUuid(agencyId,'agency_id'), user=assertUuid(userId,'user_id'), p=provider(rawProvider);
  const stamp=now();
  await serviceRequest(queryPath('enterprise_integration_connections',{
    agency_id:`eq.${agency}`,user_id:`eq.${user}`,provider:`eq.${p}`
  }),{
    method:'PATCH',
    body:{status:ok?'CONNECTED':'ERROR',last_health_at:stamp,last_error_code:ok?null:String(errorCode||'provider_error').slice(0,120),last_error_at:ok?null:stamp,updated_at:stamp},
    prefer:'return=minimal'
  });
}

export async function revokeIntegrationConnection({agencyId,userId,provider:rawProvider}){
  const agency=assertUuid(agencyId,'agency_id'), user=assertUuid(userId,'user_id'), p=provider(rawProvider);
  const stamp=now();
  await serviceRequest(queryPath('enterprise_integration_connections',{
    agency_id:`eq.${agency}`,user_id:`eq.${user}`,provider:`eq.${p}`
  }),{
    method:'PATCH',
    body:{status:'REVOKED',access_token_ciphertext:null,refresh_token_ciphertext:null,revoked_at:stamp,updated_at:stamp},
    prefer:'return=minimal'
  });
}

export async function auditIntegration({agencyId,userId,provider:rawProvider,action,metadata={}}){
  const agency=assertUuid(agencyId,'agency_id'), user=assertUuid(userId,'user_id'), p=provider(rawProvider);
  await serviceRequest('/rest/v1/audit_events',{
    method:'POST',
    body:{id:randomUUID(),agency_id:agency,actor_user_id:user,action,entity_type:'integration',entity_id:null,metadata:{provider:p,...metadata}},
    prefer:'return=minimal'
  });
}
