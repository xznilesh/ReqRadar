import { createHash, randomBytes } from 'node:crypto';
import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { mutationRequestIsTrusted, declaredBodyWithin } from '@/lib/request-security';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from '@/lib/supabase-api';

export const runtime='nodejs';
export const dynamic='force-dynamic';

const PROD=process.env.NODE_ENV==='production';
const STATE_COOKIE=PROD?'__Host-xz_sso_state':'xz_sso_state';
const VERIFIER_COOKIE=PROD?'__Host-xz_sso_verifier':'xz_sso_verifier';
const NEXT_COOKIE=PROD?'__Host-xz_sso_next':'xz_sso_next';

function cookieOptions(){
  return {httpOnly:true,secure:PROD,sameSite:'lax',path:'/',maxAge:600};
}
function safeNext(value){
  const next=String(value||'/').trim();
  return next.startsWith('/')&&!next.startsWith('//')?next:'/';
}
function domainOk(value){
  return /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i.test(String(value||''));
}
function uuid(value){
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value||''));
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,16*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  if(!SUPABASE_URL||!SUPABASE_PUBLISHABLE_KEY)return NextResponse.json({ok:false,error:'sso_not_configured'},{status:503});

  let body;
  try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  const domain=String(body?.domain||'').trim().toLowerCase();
  const providerId=String(body?.providerId||'').trim();
  if((domain?1:0)+(providerId?1:0)!==1)return NextResponse.json({ok:false,error:'domain_or_provider_required'},{status:400});
  if(domain&&!domainOk(domain))return NextResponse.json({ok:false,error:'invalid_sso_domain'},{status:400});
  if(providerId&&!uuid(providerId))return NextResponse.json({ok:false,error:'invalid_sso_provider'},{status:400});

  const verifier=randomBytes(48).toString('base64url');
  const challenge=createHash('sha256').update(verifier).digest('base64url');
  const state=randomBytes(32).toString('base64url');
  const callback=new URL('/api/auth/sso/callback',req.nextUrl.origin);
  callback.searchParams.set('state',state);

  const response=await fetch(`${SUPABASE_URL}/auth/v1/sso`,{
    method:'POST',
    headers:{
      apikey:SUPABASE_PUBLISHABLE_KEY,
      'content-type':'application/json',
      accept:'application/json'
    },
    body:JSON.stringify({
      ...(domain?{domain}:{provider_id:providerId}),
      redirect_to:callback.toString(),
      skip_http_redirect:true,
      code_challenge:challenge,
      code_challenge_method:'s256'
    }),
    cache:'no-store'
  }).catch(()=>null);
  const data=response?await response.json().catch(()=>null):null;
  if(!response?.ok||!data?.url)return NextResponse.json({ok:false,error:'sso_provider_unavailable'},{status:503});

  let redirect;
  try{redirect=new URL(data.url)}catch{return NextResponse.json({ok:false,error:'invalid_sso_redirect'},{status:503})}
  if(PROD&&redirect.protocol!=='https:')return NextResponse.json({ok:false,error:'insecure_sso_redirect'},{status:503});

  const store=await cookies();
  store.set(STATE_COOKIE,state,cookieOptions());
  store.set(VERIFIER_COOKIE,verifier,cookieOptions());
  store.set(NEXT_COOKIE,safeNext(body?.next),cookieOptions());

  return NextResponse.json({ok:true,url:redirect.toString()},{headers:{'Cache-Control':'no-store'}});
}
