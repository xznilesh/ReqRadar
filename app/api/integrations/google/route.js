import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { googleAuthorizationUrl } from '@/lib/integrations/google';
import { createOauthState, integrationCookieOptions } from '@/lib/integrations/oauth-state';
import { auditIntegration, revokeIntegrationConnection } from '@/lib/integrations/store';
import { mutationRequestIsTrusted } from '@/lib/request-security';

export const runtime='nodejs';
export const dynamic='force-dynamic';

const STATE=process.env.NODE_ENV==='production'?'__Host-xz_google_oauth_state':'xz_google_oauth_state';
const VERIFIER=process.env.NODE_ENV==='production'?'__Host-xz_google_oauth_verifier':'xz_google_oauth_verifier';

function redirectUri(req){
  const configured=String(process.env.GOOGLE_OAUTH_REDIRECT_URI||'').trim();
  if(configured)return configured;
  if(process.env.NODE_ENV==='production')throw new Error('google_redirect_uri_missing');
  return new URL('/api/integrations/google/callback',req.nextUrl.origin).toString();
}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.redirect(new URL('/login',req.nextUrl.origin),303);
  try{
    const {state,verifier,challenge}=createOauthState();
    const store=await cookies();
    store.set(STATE,state,integrationCookieOptions());
    store.set(VERIFIER,verifier,integrationCookieOptions());
    return NextResponse.redirect(googleAuthorizationUrl({redirectUri:redirectUri(req),state,challenge}),303);
  }catch(error){
    console.error('google_oauth_start_failed',error?.message||'');
    return NextResponse.redirect(new URL('/settings?focus=integrations&error=google_connect',req.nextUrl.origin),303);
  }
}

export async function DELETE(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  try{
    await revokeIntegrationConnection({agencyId:user.agency_id,userId:user.id,provider:'GOOGLE'});
    await auditIntegration({agencyId:user.agency_id,userId:user.id,provider:'GOOGLE',action:'integration.google_revoked'});
    return NextResponse.json({ok:true},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'google_disconnect_failed'},{status:503});
  }
}
