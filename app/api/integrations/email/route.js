import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { mutationRequestIsTrusted, declaredBodyWithin } from '@/lib/request-security';
import { googleRecentMessages, googleSendEmail } from '@/lib/integrations/google';
import { microsoftRecentMessages, microsoftSendEmail } from '@/lib/integrations/microsoft';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function provider(value){const p=String(value||'').toLowerCase();return ['google','microsoft'].includes(p)?p:null}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  const p=provider(req.nextUrl.searchParams.get('provider'));
  if(!p)return NextResponse.json({ok:false,error:'invalid_provider'},{status:400});
  const maxResults=req.nextUrl.searchParams.get('limit')||20;
  try{
    const messages=p==='google'
      ?await googleRecentMessages({agencyId:user.agency_id,userId:user.id,maxResults})
      :await microsoftRecentMessages({agencyId:user.agency_id,userId:user.id,maxResults});
    return NextResponse.json({ok:true,provider:p,messages},{headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'email_integration_unavailable',provider:p},{status:503});
  }
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,256*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  let body;try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  const p=provider(body?.provider);
  if(!p)return NextResponse.json({ok:false,error:'invalid_provider'},{status:400});
  try{
    const result=p==='google'
      ?await googleSendEmail({agencyId:user.agency_id,userId:user.id,to:body.to,subject:body.subject,textBody:body.text})
      :await microsoftSendEmail({agencyId:user.agency_id,userId:user.id,to:body.to,subject:body.subject,textBody:body.text});
    return NextResponse.json({ok:true,provider:p,result},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'email_send_failed',provider:p},{status:503});
  }
}
