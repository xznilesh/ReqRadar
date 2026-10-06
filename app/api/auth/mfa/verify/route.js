import { NextResponse } from 'next/server';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import { setSession } from '@/lib/auth';
import {
  clearPendingMfa,
  logoutSupabaseAuth,
  pendingMfa,
  ssoProviderFromToken,
  tokenHasSaml,
  verifyTotp
} from '@/lib/mfa-auth';
import { createWorkspaceSessionFromSso, resolveWorkspaceForSso } from '@/lib/sso-auth';

export const runtime='nodejs';
export const dynamic='force-dynamic';

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,8*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});

  const pending=await pendingMfa();
  if(!pending?.accessToken)return NextResponse.json({ok:false,error:'mfa_session_missing'},{status:401});
  if(!tokenHasSaml(pending.accessToken)){
    await clearPendingMfa();
    return NextResponse.json({ok:false,error:'mfa_sso_required'},{status:401});
  }

  let body;
  try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  const factorId=String(body?.factorId||'');
  const code=String(body?.code||'');

  try{
    const verified=await verifyTotp({accessToken:pending.accessToken,factorId,code});
    if(!tokenHasSaml(verified.accessToken))throw new Error('mfa_sso_method_missing');

    const resolved=await resolveWorkspaceForSso({email:verified.user.email});
    const appSession=await createWorkspaceSessionFromSso({
      email:verified.user.email,
      authUserId:verified.user.id,
      providerId:ssoProviderFromToken(verified.accessToken),
      resolved
    });
    await setSession(appSession.token);
    await logoutSupabaseAuth(verified.accessToken);
    await clearPendingMfa();

    return NextResponse.json({ok:true,aal:'aal2',next:pending.next},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    const clientErrors=new Set([
      'invalid_mfa_factor','invalid_mfa_code','mfa_factor_not_owned',
      'mfa_aal2_required','mfa_sso_method_missing'
    ]);
    const provisioningErrors=new Set([
      'sso_user_not_provisioned','sso_user_ambiguous','sso_workspace_missing','sso_workspace_selection_required'
    ]);
    if(provisioningErrors.has(error?.message))await clearPendingMfa();
    const status=clientErrors.has(error?.message)?422:provisioningErrors.has(error?.message)?403:503;
    return NextResponse.json({ok:false,error:error?.message||'mfa_verify_failed'},{status});
  }
}
