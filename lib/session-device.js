import { createHash, createHmac } from 'node:crypto';
import { serviceRequest, queryPath, serviceStoreConfigured } from './service-store.js';

function bounded(value,max=160){return String(value||'').trim().slice(0,max)}
function browserFromUa(ua){
  const value=String(ua||'');
  if(/Edg\//.test(value))return 'Edge';
  if(/Chrome\//.test(value)&&!/Chromium/.test(value))return 'Chrome';
  if(/Firefox\//.test(value))return 'Firefox';
  if(/Safari\//.test(value)&&!/Chrome\//.test(value))return 'Safari';
  return 'Other';
}
function osFromUa(ua){
  const value=String(ua||'');
  if(/Windows NT/.test(value))return 'Windows';
  if(/Android/.test(value))return 'Android';
  if(/iPhone|iPad|iPod/.test(value))return 'iOS';
  if(/Mac OS X/.test(value))return 'macOS';
  if(/Linux/.test(value))return 'Linux';
  return 'Other';
}
function hash(value){return createHash('sha256').update(String(value||'')).digest('hex')}
function keyedHash(value){
  const key=String(process.env.XZRECRUITER_TELEMETRY_HASH_KEY||'').trim();
  if(!key)return null;
  return createHmac('sha256',key).update(String(value||'')).digest('hex');
}
function clientIp(request){
  const forwarded=String(request?.headers?.get?.('x-forwarded-for')||'').split(',')[0].trim();
  return forwarded||String(request?.headers?.get?.('x-real-ip')||'').trim();
}

export function sessionDeviceMetadata(request){
  const ua=bounded(request?.headers?.get?.('user-agent')||'',512);
  const browser=browserFromUa(ua);
  const os=osFromUa(ua);
  const metadata={
    device_label:`${browser} / ${os}`,
    browser,
    os,
    user_agent_hash:ua?hash(ua):null,
    ip_hash:keyedHash(clientIp(request)),
    captured_at:new Date().toISOString()
  };
  return Object.fromEntries(Object.entries(metadata).filter(([,value])=>value!==null&&value!==''));
}

export async function attachDeviceMetadataToSession({token,request}){
  if(!serviceStoreConfigured())throw new Error('device_session_store_not_configured');
  const raw=String(token||'');
  if(!raw)throw new Error('missing_session_token');
  const tokenHash=hash(raw);
  const metadata=sessionDeviceMetadata(request);
  const rows=await serviceRequest(queryPath('user_sessions',{
    select:'id',
    token_hash:`eq.${tokenHash}`,
    revoked_at:'is.null',
    limit:'1'
  }),{
    method:'PATCH',
    body:{device_metadata:metadata,last_seen_at:new Date().toISOString()},
    prefer:'return=representation'
  });
  if(!Array.isArray(rows)||!rows[0]?.id)throw new Error('session_device_attach_failed');
  return {sessionId:rows[0].id,deviceMetadata:metadata};
}
