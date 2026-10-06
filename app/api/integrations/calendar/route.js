import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { mutationRequestIsTrusted, declaredBodyWithin } from '@/lib/request-security';
import { googleCalendarEvents, googleCreateCalendarEvent } from '@/lib/integrations/google';
import { microsoftCalendarEvents, microsoftCreateCalendarEvent } from '@/lib/integrations/microsoft';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function provider(value){const p=String(value||'').toLowerCase();return ['google','microsoft'].includes(p)?p:null}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  const p=provider(req.nextUrl.searchParams.get('provider'));
  if(!p)return NextResponse.json({ok:false,error:'invalid_provider'},{status:400});
  try{
    const start=req.nextUrl.searchParams.get('start')||new Date().toISOString();
    const end=req.nextUrl.searchParams.get('end')||null;
    const maxResults=req.nextUrl.searchParams.get('limit')||50;
    const events=p==='google'
      ?await googleCalendarEvents({agencyId:user.agency_id,userId:user.id,timeMin:start,maxResults})
      :await microsoftCalendarEvents({agencyId:user.agency_id,userId:user.id,startDateTime:start,endDateTime:end,maxResults});
    return NextResponse.json({ok:true,provider:p,events},{headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'calendar_integration_unavailable',provider:p},{status:503});
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
      ?await googleCreateCalendarEvent({agencyId:user.agency_id,userId:user.id,event:body.event})
      :await microsoftCreateCalendarEvent({agencyId:user.agency_id,userId:user.id,event:body.event});
    return NextResponse.json({ok:true,provider:p,event:result},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'calendar_create_failed',provider:p},{status:503});
  }
}
