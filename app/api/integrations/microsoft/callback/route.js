import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { exchangeMicrosoftCode, microsoftUserInfo, persistMicrosoftConnection } from '@/lib/integrations/microsoft';
import { integrationCookieOptions, oauthStateMatches } from '@/lib/integrations/oauth-state';
import { auditIntegration } from '@/lib/integrations/store';

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
async function clear(store){store.set(STATE,'',integrationCookieOptions(0));store.set(VERIFIER,'',integrationCookieOptions(0))}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.redirect(new URL('/login',req.nextUrl.origin),303);
  const store=await cookies();
  const expected=store.get(STATE)?.value||'';
  const verifier=store.get(VERIFIER)?.value||'';
  const state=req.nextUrl.searchParams.get('state')||'';
  const code=req.nextUrl.searchParams.get('code')||'';
  if(!oauthStateMatches(expected,state)||!verifier||!code){
    await clear(store);
    return NextResponse.redirect(new URL('/settings?focus=integrations&error=microsoft_state',req.nextUrl.origin),303);
  }
  try{
    const tokens=await exchangeMicrosoftCode({code,redirectUri:redirectUri(req),verifier});
    const profile=await microsoftUserInfo(tokens.access_token);
    if(!profile?.id||!(profile?.mail||profile?.userPrincipalName))throw new Error('microsoft_identity_incomplete');
    await persistMicrosoftConnection({agencyId:user.agency_id,userId:user.id,tokens,profile});
    await auditIntegration({agencyId:user.agency_id,userId:user.id,provider:'MICROSOFT',action:'integration.microsoft_connected',metadata:{external_account_id:profile.id}});
    await clear(store);
    return NextResponse.redirect(new URL('/settings?focus=integrations&connected=microsoft',req.nextUrl.origin),303);
  }catch(error){
    await clear(store);
    console.error('microsoft_oauth_callback_failed',error?.status||'',error?.message||'');
    return NextResponse.redirect(new URL('/settings?focus=integrations&error=microsoft_callback',req.nextUrl.origin),303);
  }
}
