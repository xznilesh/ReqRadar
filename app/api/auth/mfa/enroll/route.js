import { NextResponse } from 'next/server';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import { getAuthUser } from '@/lib/supabase-api';
import {
  enrollTotp,
  listMfaFactors,
  pendingMfa,
  tokenHasAal2,
  tokenHasSaml
} from '@/lib/mfa-auth';

export const runtime='nodejs';
export const dynamic='force-dynamic';

async function context(){
  const pending=await pendingMfa();
  if(!pending?.accessToken)throw new Error('mfa_session_missing');
  if(!tokenHasSaml(pending.accessToken))throw new Error('mfa_sso_required');
  const user=await getAuthUser(pending.accessToken);
  if(!user?.id||!user?.email)throw new Error('mfa_identity_invalid');
  return {pending,user};
}

export async function GET(){
  try{
    const {pending,user}=await context();
    if(tokenHasAal2(pending.accessToken)){
      return NextResponse.json({ok:true,mode:'verified',next:pending.next},{headers:{'Cache-Control':'no-store'}});
    }
    const factors=await listMfaFactors(pending.accessToken);
    const verified=factors.filter(factor=>String(factor.type||'').toLowerCase()==='totp'&&String(factor.status||'').toLowerCase()==='verified');
    return NextResponse.json({
      ok:true,
      mode:verified.length?'challenge':'enroll',
      email:user.email,
      factors:verified.map(factor=>({id:factor.id,friendlyName:factor.friendlyName||'Authenticator app'}))
    },{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    const status=['mfa_session_missing','mfa_sso_required'].includes(error?.message)?401:503;
    return NextResponse.json({ok:false,error:error?.message||'mfa_unavailable'},{status});
  }
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,8*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  try{
    const {pending}=await context();
    const factors=await listMfaFactors(pending.accessToken);
    const verified=factors.filter(factor=>String(factor.type||'').toLowerCase()==='totp'&&String(factor.status||'').toLowerCase()==='verified');
    if(verified.length){
      return NextResponse.json({ok:false,error:'mfa_already_enrolled',factors:verified.map(f=>({id:f.id,friendlyName:f.friendlyName||'Authenticator app'}))},{status:409});
    }
    const existingUnverified=factors.filter(factor=>String(factor.type||'').toLowerCase()==='totp'&&String(factor.status||'').toLowerCase()==='unverified');
    if(existingUnverified.length){
      return NextResponse.json({ok:false,error:'mfa_unverified_factor_exists'},{status:409});
    }
    const enrollment=await enrollTotp(pending.accessToken);
    return NextResponse.json({ok:true,mode:'enroll',...enrollment},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    const status=error?.message==='mfa_session_missing'?401:error?.message==='invalid_mfa_factor'?400:503;
    return NextResponse.json({ok:false,error:error?.message||'mfa_enroll_failed'},{status});
  }
}
