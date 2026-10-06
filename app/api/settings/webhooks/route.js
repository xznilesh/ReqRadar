import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import { createWebhookEndpoint, dispatchWebhook, listWebhookEndpoints, revokeWebhookEndpoint } from '@/lib/integrations/webhooks';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function admin(user){return user?.id&&user?.agency_id&&['OWNER','ADMIN'].includes(String(user.role||'').toUpperCase())}

export async function GET(){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  try{return NextResponse.json({ok:true,endpoints:await listWebhookEndpoints({agencyId:user.agency_id})},{headers:{'Cache-Control':'private, no-store'}})}
  catch{return NextResponse.json({ok:false,error:'webhook_store_unavailable'},{status:503})}
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,64*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  let body;try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  try{
    const action=String(body?.action||'create').toLowerCase();
    if(action==='revoke'){
      const result=await revokeWebhookEndpoint({agencyId:user.agency_id,endpointId:body?.endpointId});
      return NextResponse.json(result,{status:result.ok?200:404,headers:{'Cache-Control':'no-store'}});
    }
    if(action==='test'){
      const result=await dispatchWebhook({agencyId:user.agency_id,eventType:'webhook.test',payload:{ok:true,workspace_id:user.agency_id,sent_at:new Date().toISOString()}});
      return NextResponse.json({ok:true,...result},{headers:{'Cache-Control':'no-store'}});
    }
    const created=await createWebhookEndpoint({agencyId:user.agency_id,userId:user.id,url:body?.url,events:body?.events});
    return NextResponse.json({ok:true,...created},{status:201,headers:{'Cache-Control':'no-store'}});
  }catch(error){
    console.error('webhook_admin_failed',error?.message||'');
    return NextResponse.json({ok:false,error:'webhook_operation_failed'},{status:503});
  }
}
