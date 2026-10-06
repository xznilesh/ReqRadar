import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { microsoftAuthorizationUrl } from '@/lib/integrations/microsoft';
import { createOauthState, integrationCookieOptions } from '@/lib/integrations/oauth-state';
import { auditIntegration, revokeIntegrationConnection } from '@/lib/integrations/store';
import { mutationRequestIsTrusted } from '@/lib/request-security';

export const runtime='nodejs';
export const dynamic='force-dynamic';

const STATE=process.env.NODE_ENV==='production'?'__Host-xz_microsoft_oauth_state':'xz_microsoft_oauth_state';
const VERIFIER=process.env.NODE_ENV==='production'?'__Host-xz_microsoft_oauth_verifier':'xz_microsoft_oauth_verifier';

function redirectUri(req){
  const configured=String(process.env.MICROSOFT_OAUTH_REDIRECT_URI||'').trim();
  if(configured)return configured;
  if(process.env.NODE_ENV==='production')throw new Error('microsoft_redirect_uri_missing');
  return new URL('/api/integrations/microsoft/callback',req.nextUrl.origin).toString();
}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.redirect(new URL('/login',req.nextUrl.origin),303);
  try{
    const {state,verifier,challenge}=createOauthState();
    const store=await cookies();
    store.set(STATE,state,integrationCookieOptions());
    store.set(VERIFIER,verifier,integrationCookieOptions());
    return NextResponse.redirect(microsoftAuthorizationUrl({redirectUri:redirectUri(req),state,challenge}),303);
  }catch(error){
    console.error('microsoft_oauth_start_failed',error?.message||'');
    return NextResponse.redirect(new URL('/settings?focus=integrations&error=microsoft_connect',req.nextUrl.origin),303);
  }
}

export async function DELETE(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  try{
    await revokeIntegrationConnection({agencyId:user.agency_id,userId:user.id,provider:'MICROSOFT'});
    await auditIntegration({agencyId:user.agency_id,userId:user.id,provider:'MICROSOFT',action:'integration.microsoft_revoked'});
    return NextResponse.json({ok:true},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'microsoft_disconnect_failed'},{status:503});
  }
}
