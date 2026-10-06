import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import { issueScimToken, revokeScimToken } from '@/lib/scim';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function admin(user){
  return user?.id&&user?.agency_id&&['OWNER','ADMIN'].includes(String(user.role||'').toUpperCase());
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,16*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  let body;
  try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  try{
    const action=String(body?.action||'create').toLowerCase();
    if(action==='revoke'){
      const result=await revokeScimToken({agencyId:user.agency_id,actorUserId:user.id,tokenId:body?.tokenId});
      return NextResponse.json(result,{status:result.ok?200:404,headers:{'Cache-Control':'private, no-store'}});
    }
    const created=await issueScimToken({
      agencyId:user.agency_id,actorUserId:user.id,label:body?.label,
      defaultRole:body?.defaultRole,expiresAt:body?.expiresAt||null
    });
    return NextResponse.json({ok:true,...created,warning:'Store this SCIM token now. It cannot be retrieved again.'},{
      status:201,headers:{'Cache-Control':'no-store'}
    });
  }catch(error){
    console.error('scim_token_admin_failed',error?.message||'');
    return NextResponse.json({ok:false,error:'scim_token_admin_failed'},{status:503});
  }
}
