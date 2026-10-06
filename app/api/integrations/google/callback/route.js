import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { exchangeGoogleCode, googleUserInfo, persistGoogleConnection } from '@/lib/integrations/google';
import { integrationCookieOptions, oauthStateMatches } from '@/lib/integrations/oauth-state';
import { auditIntegration } from '@/lib/integrations/store';

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
    return NextResponse.redirect(new URL('/settings?focus=integrations&error=google_state',req.nextUrl.origin),303);
  }
  try{
    const tokens=await exchangeGoogleCode({code,redirectUri:redirectUri(req),verifier});
    const profile=await googleUserInfo(tokens.access_token);
    if(!profile?.sub||!profile?.email)throw new Error('google_identity_incomplete');
    await persistGoogleConnection({agencyId:user.agency_id,userId:user.id,tokens,profile});
    await auditIntegration({agencyId:user.agency_id,userId:user.id,provider:'GOOGLE',action:'integration.google_connected',metadata:{external_account_id:profile.sub}});
    await clear(store);
    return NextResponse.redirect(new URL('/settings?focus=integrations&connected=google',req.nextUrl.origin),303);
  }catch(error){
    await clear(store);
    console.error('google_oauth_callback_failed',error?.status||'',error?.message||'');
    return NextResponse.redirect(new URL('/settings?focus=integrations&error=google_callback',req.nextUrl.origin),303);
  }
}
