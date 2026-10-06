import { cookies } from 'next/headers';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, getAuthUser } from '@/lib/supabase-api';

const PROD=process.env.NODE_ENV==='production';
const ACCESS_COOKIE=PROD?'__Host-xz_mfa_access':'xz_mfa_access';
const NEXT_COOKIE=PROD?'__Host-xz_mfa_next':'xz_mfa_next';
const MFA_SECONDS=10*60;

function cookieOptions(maxAge=MFA_SECONDS){
  return {httpOnly:true,secure:PROD,sameSite:'strict',path:'/',maxAge};
}
function safeNext(value){
  const next=String(value||'/dashboard');
  return next.startsWith('/')&&!next.startsWith('//')?next:'/dashboard';
}
function factorId(value){
  const id=String(value||'');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id))throw new Error('invalid_mfa_factor');
  return id;
}
function jwtPayload(token){
  try{return JSON.parse(Buffer.from(String(token||'').split('.')[1]||'','base64url').toString('utf8'))}
  catch{return null}
}
export function tokenHasAal2(token){
  const payload=jwtPayload(token);
  return payload?.aal==='aal2'&&Array.isArray(payload?.amr)&&payload.amr.some(item=>String(item?.method||'').toLowerCase()==='totp');
}
export function tokenHasSaml(token){
  const payload=jwtPayload(token);
  return Array.isArray(payload?.amr)&&payload.amr.some(item=>String(item?.method||'').toLowerCase()==='sso/saml');
}
export function ssoProviderFromToken(token){
  const payload=jwtPayload(token);
  const method=Array.isArray(payload?.amr)?payload.amr.find(item=>String(item?.method||'').toLowerCase()==='sso/saml'):null;
  return method?.provider||payload?.app_metadata?.provider||null;
}
export function requireSsoMfa(){
  const value=String(process.env.XZRECRUITER_REQUIRE_SSO_MFA||'').trim().toLowerCase();
  return PROD?value!=='false':value==='true';
}
export function enterpriseDomainRequiresSso(email){
  const domain=String(email||'').trim().toLowerCase().split('@').pop()||'';
  const domains=String(process.env.XZRECRUITER_ENTERPRISE_SSO_DOMAINS||'')
    .split(',').map(value=>value.trim().toLowerCase()).filter(Boolean);
  return Boolean(domain)&&domains.includes(domain);
}
export async function setPendingMfa({accessToken,next='/dashboard'}){
  if(!accessToken)throw new Error('missing_mfa_access_token');
  const user=await getAuthUser(accessToken);
  if(!user?.id||!user?.email)throw new Error('invalid_mfa_identity');
  const store=await cookies();
  store.set(ACCESS_COOKIE,accessToken,cookieOptions());
  store.set(NEXT_COOKIE,safeNext(next),cookieOptions());
  return user;
}
export async function pendingMfa(){
  const store=await cookies();
  const accessToken=store.get(ACCESS_COOKIE)?.value||'';
  const next=safeNext(store.get(NEXT_COOKIE)?.value||'/dashboard');
  if(!accessToken)return null;
  return {accessToken,next};
}
export async function clearPendingMfa(){
  const store=await cookies();
  store.set(ACCESS_COOKIE,'',cookieOptions(0));
  store.set(NEXT_COOKIE,'',cookieOptions(0));
}
async function authRequest(path,{method='GET',accessToken,body}={}){
  if(!SUPABASE_URL||!SUPABASE_PUBLISHABLE_KEY)throw new Error('mfa_not_configured');
  if(!accessToken)throw new Error('mfa_session_missing');
  const response=await fetch(SUPABASE_URL+path,{
    method,
    headers:{
      apikey:SUPABASE_PUBLISHABLE_KEY,
      authorization:`Bearer ${accessToken}`,
      accept:'application/json',
      ...(body!==undefined?{'content-type':'application/json'}:{})
    },
    ...(body!==undefined?{body:JSON.stringify(body)}:{}),
    cache:'no-store'
  });
  const data=await response.json().catch(()=>null);
  if(!response.ok){
    const error=new Error('mfa_provider_request_failed');
    error.status=response.status;
    error.details=data;
    throw error;
  }
  return data;
}
export async function listMfaFactors(accessToken){
  const data=await authRequest('/auth/v1/factors',{accessToken});
  const all=Array.isArray(data)?data:[
    ...(Array.isArray(data?.all)?data.all:[]),
    ...(Array.isArray(data?.totp)?data.totp:[]),
    ...(Array.isArray(data?.phone)?data.phone:[])
  ];
  const unique=new Map();
  for(const factor of all){
    if(!factor?.id)continue;
    unique.set(factor.id,{
      id:factor.id,
      type:factor.factor_type||factor.type||null,
      status:factor.status||null,
      friendlyName:factor.friendly_name||null,
      createdAt:factor.created_at||null,
      updatedAt:factor.updated_at||null
    });
  }
  return [...unique.values()];
}
export async function enrollTotp(accessToken){
  const data=await authRequest('/auth/v1/factors',{
    method:'POST',accessToken,
    body:{factor_type:'totp',friendly_name:'XZ Recruiter'}
  });
  if(!data?.id||!data?.totp?.secret)throw new Error('mfa_enrollment_invalid_response');
  let qrCode=String(data.totp.qr_code||'');
  if(qrCode.startsWith('<svg'))qrCode='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(qrCode);
  return {
    factorId:data.id,
    friendlyName:data.friendly_name||'XZ Recruiter',
    qrCode,
    secret:String(data.totp.secret||''),
    uri:String(data.totp.uri||'')
  };
}
export async function verifyTotp({accessToken,factorId:rawFactorId,code}){
  const id=factorId(rawFactorId);
  const normalizedCode=String(code||'').replace(/\s+/g,'');
  if(!/^\d{6,10}$/.test(normalizedCode))throw new Error('invalid_mfa_code');

  const factors=await listMfaFactors(accessToken);
  const factor=factors.find(item=>item.id===id&&String(item.type||'').toLowerCase()==='totp');
  if(!factor)throw new Error('mfa_factor_not_owned');

  const challenge=await authRequest(`/auth/v1/factors/${encodeURIComponent(id)}/challenge`,{
    method:'POST',accessToken,body:{}
  });
  if(!challenge?.id)throw new Error('mfa_challenge_invalid_response');

  const verified=await authRequest(`/auth/v1/factors/${encodeURIComponent(id)}/verify`,{
    method:'POST',accessToken,
    body:{challenge_id:challenge.id,code:normalizedCode}
  });
  const verifiedToken=verified?.access_token||verified?.session?.access_token||'';
  if(!verifiedToken||!tokenHasAal2(verifiedToken))throw new Error('mfa_aal2_required');
  const user=await getAuthUser(verifiedToken);
  if(!user?.id||!user?.email)throw new Error('mfa_identity_invalid');
  return {accessToken:verifiedToken,user};
}
export async function logoutSupabaseAuth(accessToken){
  if(!accessToken||!SUPABASE_URL||!SUPABASE_PUBLISHABLE_KEY)return;
  await fetch(`${SUPABASE_URL}/auth/v1/logout?scope=local`,{
    method:'POST',
    headers:{apikey:SUPABASE_PUBLISHABLE_KEY,authorization:`Bearer ${accessToken}`},
    cache:'no-store'
  }).catch(()=>null);
}
