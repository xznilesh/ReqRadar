import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import { createApiKey, listApiKeys, revokeApiKey, rotateApiKey } from '@/lib/integrations/api-keys';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function admin(user){return user?.id&&user?.agency_id&&['OWNER','ADMIN'].includes(String(user.role||'').toUpperCase())}

export async function GET(){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  try{return NextResponse.json({ok:true,keys:await listApiKeys({agencyId:user.agency_id})},{headers:{'Cache-Control':'private, no-store'}})}
  catch{return NextResponse.json({ok:false,error:'api_key_store_unavailable'},{status:503})}
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,32*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  let body;try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  try{
    const action=String(body?.action||'create').toLowerCase();
    if(action==='revoke'){
      const result=await revokeApiKey({agencyId:user.agency_id,userId:user.id,keyId:body?.keyId});
      return NextResponse.json(result,{status:result.ok?200:404,headers:{'Cache-Control':'no-store'}});
    }
    if(action==='rotate'){
      const created=await rotateApiKey({agencyId:user.agency_id,userId:user.id,keyId:body?.keyId});
      return NextResponse.json({ok:true,...created,warning:'Store this rotated API key now. It cannot be retrieved again.'},{status:201,headers:{'Cache-Control':'no-store'}});
    }
    const created=await createApiKey({agencyId:user.agency_id,userId:user.id,name:body?.name,scopes:body?.scopes,expiresAt:body?.expiresAt||null});
    return NextResponse.json({ok:true,...created,warning:'Store this API key now. It cannot be retrieved again.'},{status:201,headers:{'Cache-Control':'no-store'}});
  }catch(error){
    console.error('api_key_admin_failed',error?.message||'');
    return NextResponse.json({ok:false,error:'api_key_operation_failed'},{status:503});
  }
}
