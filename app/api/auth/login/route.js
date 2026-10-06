import { NextResponse } from 'next/server';
import { rpc } from '@/lib/supabase-api';
import { setSession } from '@/lib/auth';
import { consumeRateLimit,rateLimitIdentityForRequest } from '@/lib/rate-limit';
import { mutationRequestIsTrusted,declaredBodyWithin } from '@/lib/request-security';\nimport { attachDeviceMetadataToSession } from '@/lib/session-device';

const errors={
  email_unverified:['Verify your work email before opening the dashboard.',403],
  account_disabled:['This account is disabled.',403],
  temporarily_locked:['Too many sign-in attempts. Try again in a few minutes.',429],
  invalid_credentials:['Email or password is incorrect.',401]
};

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({error:'Invalid request origin.'},{status:403});
  if(!declaredBodyWithin(req,16*1024))return NextResponse.json({error:'Request is too large.'},{status:413});
  let body;
  try{body=await req.json();}
  catch{return NextResponse.json({error:'Invalid request.'},{status:400});}

  const email=String(body.email||'').trim().toLowerCase();
  try{
    const gate=await consumeRateLimit({
      scope:'auth:login',identity:rateLimitIdentityForRequest(req,email),limit:10,windowSeconds:900
    });
    if(!gate.allowed)return NextResponse.json({error:'Too many sign-in attempts. Try again later.',code:'rate_limited'},{status:429});
  }catch{
    return NextResponse.json({error:'Sign in is temporarily unavailable.'},{status:503});
  }

  try{
    const result=await rpc('xzrecruiter_login',{p_email:email,p_password:String(body.password||'')});
    if(!result?.ok||!result?.token){
      const code=result?.error||'invalid_credentials';
      const [message,status]=errors[code]||errors.invalid_credentials;
      return NextResponse.json({error:message,code},{status});
    }
    try{
      await attachDeviceMetadataToSession({token:result.token,request:req});
    }catch(deviceError){
      await rpc('xzrecruiter_logout',{p_token:result.token}).catch(()=>null);
      throw deviceError;
    }
    await setSession(result.token);
    return NextResponse.json({ok:true});
  }catch(error){
    console.error('login_rpc_failed',error?.status||'',error?.message||'');
    return NextResponse.json({error:'Sign in is temporarily unavailable.'},{status:503});
  }
}
