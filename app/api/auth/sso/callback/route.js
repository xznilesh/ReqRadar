import { timingSafeEqual } from 'node:crypto';
import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { getAuthUser, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '@/lib/supabase-api';
import { setSession } from '@/lib/auth';
import { createWorkspaceSessionFromSso } from '@/lib/sso-auth';

export const runtime='nodejs';
export const dynamic='force-dynamic';

const PROD=process.env.NODE_ENV==='production';
const STATE_COOKIE=PROD?'__Host-xz_sso_state':'xz_sso_state';
const VERIFIER_COOKIE=PROD?'__Host-xz_sso_verifier':'xz_sso_verifier';
const NEXT_COOKIE=PROD?'__Host-xz_sso_next':'xz_sso_next';

function clearOptions(){return {httpOnly:true,secure:PROD,sameSite:'lax',path:'/',maxAge:0}}
function safeNext(value){const next=String(value||'/');return next.startsWith('/')&&!next.startsWith('//')?next:'/'}
function stateMatches(expected,received){
  const a=Buffer.from(String(expected||''));
  const b=Buffer.from(String(received||''));
  return a.length>0&&a.length===b.length&&timingSafeEqual(a,b);
}
function jwtPayload(token){
  try{return JSON.parse(Buffer.from(String(token||'').split('.')[1]||'','base64url').toString('utf8'))}
  catch{return null}
}
function ssoMethod(payload){
  const amr=Array.isArray(payload?.amr)?payload.amr:[];
  return amr.find(item=>String(item?.method||'').toLowerCase()==='sso/saml')||null;
}
async function cleanup(store){
  store.set(STATE_COOKIE,'',clearOptions());
  store.set(VERIFIER_COOKIE,'',clearOptions());
  store.set(NEXT_COOKIE,'',clearOptions());
}
async function fail(req,store,reason){
  await cleanup(store);
  const url=new URL('/login',req.nextUrl.origin);
  url.searchParams.set('error',reason);
  return NextResponse.redirect(url,303);
}

export async function GET(req){
  const store=await cookies();
  const state=req.nextUrl.searchParams.get('state')||'';
  const code=req.nextUrl.searchParams.get('code')||'';
  const expectedState=store.get(STATE_COOKIE)?.value||'';
  const verifier=store.get(VERIFIER_COOKIE)?.value||'';
  const next=safeNext(store.get(NEXT_COOKIE)?.value||'/');

  if(!stateMatches(expectedState,state))return fail(req,store,'sso_state_invalid');
  if(!code||!verifier)return fail(req,store,'sso_callback_invalid');
  if(!SUPABASE_URL||!SUPABASE_PUBLISHABLE_KEY)return fail(req,store,'sso_not_configured');

  try{
    const exchange=await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=pkce`,{
      method:'POST',
      headers:{
        apikey:SUPABASE_PUBLISHABLE_KEY,
        'content-type':'application/json',
        accept:'application/json'
      },
      body:JSON.stringify({auth_code:code,code_verifier:verifier}),
      cache:'no-store'
    });
    const session=await exchange.json().catch(()=>null);
    if(!exchange.ok||!session?.access_token)return fail(req,store,'sso_code_exchange_failed');

    const payload=jwtPayload(session.access_token);
    const method=ssoMethod(payload);
    if(!method)return fail(req,store,'sso_method_not_verified');

    const authUser=await getAuthUser(session.access_token);
    if(!authUser?.id||!authUser?.email)return fail(req,store,'sso_identity_incomplete');

    const appSession=await createWorkspaceSessionFromSso({
      email:authUser.email,
      authUserId:authUser.id,
      providerId:method.provider||payload?.app_metadata?.provider||null
    });
    await setSession(appSession.token);

    await fetch(`${SUPABASE_URL}/auth/v1/logout?scope=local`,{
      method:'POST',
      headers:{
        apikey:SUPABASE_PUBLISHABLE_KEY,
        authorization:`Bearer ${session.access_token}`
      },
      cache:'no-store'
    }).catch(()=>null);

    await cleanup(store);
    return NextResponse.redirect(new URL(next,req.nextUrl.origin),303);
  }catch(error){
    const reason=[
      'sso_user_not_provisioned',
      'sso_user_ambiguous',
      'sso_workspace_missing',
      'sso_workspace_selection_required'
    ].includes(error?.message)?error.message:'sso_login_failed';
    return fail(req,store,reason);
  }
}
