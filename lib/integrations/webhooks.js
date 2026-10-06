import { createHmac, randomBytes, randomUUID, timingSafeEqual, createHash } from 'node:crypto';
import { assertUuid, queryPath, serviceRequest } from '../service-store.js';
import { decryptIntegrationSecret, encryptIntegrationSecret } from './crypto.js';

const MAX_SKEW_SECONDS=300;
function bodyString(payload){return typeof payload==='string'?payload:JSON.stringify(payload)}
function digest(payload){return createHash('sha256').update(bodyString(payload)).digest('hex')}
function sign(secret,timestamp,eventId,payload){return createHmac('sha256',secret).update(`${timestamp}.${eventId}.${bodyString(payload)}`).digest('hex')}

export function verifyWebhookSignature({secret,timestamp,eventId,payload,signature,nowSeconds=Math.floor(Date.now()/1000),seenEventIds=new Set()}){
  const ts=Number(timestamp);
  if(!Number.isFinite(ts)||Math.abs(nowSeconds-ts)>MAX_SKEW_SECONDS)throw new Error('webhook_replay_window');
  if(seenEventIds.has(String(eventId)))throw new Error('webhook_replay_detected');
  const expected='v1='+sign(secret,ts,eventId,payload);
  const a=Buffer.from(expected),b=Buffer.from(String(signature||''));
  if(a.length!==b.length||!timingSafeEqual(a,b))throw new Error('webhook_signature_invalid');
  return true;
}

export async function createWebhookEndpoint({agencyId,userId,url,events=[]}){
  const agency=assertUuid(agencyId,'agency_id'),actor=assertUuid(userId,'user_id');
  const endpointUrl=new URL(String(url||''));
  if(endpointUrl.protocol!=='https:')throw new Error('webhook_https_required');
  const id=randomUUID(),secret='xzr_whsec_'+randomBytes(32).toString('base64url');
  const normalizedEvents=[...new Set((Array.isArray(events)?events:[]).map(v=>String(v||'').trim()).filter(v=>/^[a-z0-9_.-]{3,100}$/i.test(v)))].slice(0,100);
  await serviceRequest('/rest/v1/enterprise_webhook_endpoints',{
    method:'POST',
    body:{id,agency_id:agency,url:endpointUrl.toString(),secret_ciphertext:encryptIntegrationSecret(secret,{agencyId:agency,userId:actor,provider:'WEBHOOK',kind:id}),events:normalizedEvents,active:true,created_by_user_id:actor},
    prefer:'return=minimal'
  });
  return {id,url:endpointUrl.toString(),events:normalizedEvents,secret,warning:'Store this webhook signing secret now. It cannot be retrieved again.'};
}

export async function listWebhookEndpoints({agencyId}){
  const agency=assertUuid(agencyId,'agency_id');
  const rows=await serviceRequest(queryPath('enterprise_webhook_endpoints',{select:'id,url,events,active,last_delivery_at,last_error_code,created_at,updated_at,created_by_user_id',agency_id:`eq.${agency}`,order:'created_at.desc',limit:'200'}));
  return Array.isArray(rows)?rows:[];
}

export async function revokeWebhookEndpoint({agencyId,endpointId}){
  const agency=assertUuid(agencyId,'agency_id'),id=assertUuid(endpointId,'webhook_endpoint_id');
  const rows=await serviceRequest(queryPath('enterprise_webhook_endpoints',{select:'id',agency_id:`eq.${agency}`,id:`eq.${id}`}),{
    method:'PATCH',body:{active:false,updated_at:new Date().toISOString()},prefer:'return=representation'
  });
  return {ok:Boolean(Array.isArray(rows)&&rows[0]),id};
}

export async function dispatchWebhook({agencyId,eventType,payload,eventId=randomUUID()}){
  const agency=assertUuid(agencyId,'agency_id');
  const endpoints=await serviceRequest(queryPath('enterprise_webhook_endpoints',{select:'id,url,events,secret_ciphertext,created_by_user_id',agency_id:`eq.${agency}`,active:'eq.true',limit:'200'}));
  const targets=(Array.isArray(endpoints)?endpoints:[]).filter(row=>!Array.isArray(row.events)||row.events.length===0||row.events.includes(eventType));
  const results=[];
  for(const endpoint of targets){
    const timestamp=Math.floor(Date.now()/1000);
    const secret=decryptIntegrationSecret(endpoint.secret_ciphertext,{agencyId:agency,userId:endpoint.created_by_user_id,provider:'WEBHOOK',kind:endpoint.id});
    const signature='v1='+sign(secret,timestamp,eventId,payload);
    const deliveryId=randomUUID();
    await serviceRequest('/rest/v1/enterprise_webhook_deliveries',{method:'POST',body:{id:deliveryId,agency_id:agency,endpoint_id:endpoint.id,event_id:eventId,event_type:eventType,payload_hash:digest(payload),attempt_count:1,status:'PENDING'},prefer:'return=minimal'});
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),10_000);
    let ok=false,status=0,errorCode=null;
    try{
      const response=await fetch(endpoint.url,{method:'POST',headers:{'content-type':'application/json','x-xz-event-id':eventId,'x-xz-event-type':eventType,'x-xz-timestamp':String(timestamp),'x-xz-signature':signature,'user-agent':'XZRecruiter-Webhooks/1.0'},body:bodyString(payload),signal:controller.signal,cache:'no-store'});
      status=response.status;ok=response.ok;if(!ok)errorCode=`http_${status}`;
    }catch(error){errorCode=error?.name==='AbortError'?'timeout':'network_error'}finally{clearTimeout(timer)}
    const stamp=new Date().toISOString();
    await serviceRequest(queryPath('enterprise_webhook_deliveries',{id:`eq.${deliveryId}`}),{method:'PATCH',body:{status:ok?'DELIVERED':'FAILED',response_status:status||null,delivered_at:ok?stamp:null,last_error_code:errorCode,updated_at:stamp,next_attempt_at:ok?null:new Date(Date.now()+60_000).toISOString()},prefer:'return=minimal'});
    await serviceRequest(queryPath('enterprise_webhook_endpoints',{id:`eq.${endpoint.id}`}),{method:'PATCH',body:{last_delivery_at:stamp,last_error_code:errorCode,updated_at:stamp},prefer:'return=minimal'}).catch(()=>null);
    results.push({endpointId:endpoint.id,deliveryId,ok,status,error:errorCode});
  }
  return {eventId,eventType,deliveries:results};
}
