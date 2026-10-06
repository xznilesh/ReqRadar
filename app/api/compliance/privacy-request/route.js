import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import { createPrivacyRequest, executeCandidateDeletion, listPrivacyRequests } from '@/lib/retention-policy';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function role(user){return String(user?.role||'').trim().toUpperCase()}
function canManage(user){return user?.id&&user?.agency_id&&['OWNER','ADMIN'].includes(role(user))}
function owner(user){return user?.id&&user?.agency_id&&role(user)==='OWNER'}
function uuid(value){return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value||''))}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!canManage(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  try{
    const requests=await listPrivacyRequests({
      agencyId:user.agency_id,
      status:req.nextUrl.searchParams.get('status')||null,
      limit:req.nextUrl.searchParams.get('limit')||200
    });
    return NextResponse.json({ok:true,requests},{headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    console.error('privacy_request_list_failed',error?.message||'');
    return NextResponse.json({ok:false,error:'privacy_request_store_unavailable'},{status:503});
  }
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,32*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!canManage(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});

  let body;
  try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  const action=String(body?.action||'create').trim().toLowerCase();
  const candidateId=String(body?.candidateId||'');
  if(!uuid(candidateId))return NextResponse.json({ok:false,error:'invalid_candidate_id'},{status:400});

  try{
    if(action==='create'){
      const created=await createPrivacyRequest({
        agencyId:user.agency_id,
        candidateId,
        requestType:body?.requestType||'DELETE',
        requestedByUserId:user.id,
        dueAt:body?.dueAt||null,
        legalBasis:String(body?.legalBasis||'').slice(0,500)||null
      });
      return NextResponse.json({ok:true,request:created},{status:201,headers:{'Cache-Control':'no-store'}});
    }

    if(action==='dry_run'){
      const result=await executeCandidateDeletion({
        agencyId:user.agency_id,
        candidateId,
        privacyRequestId:body?.privacyRequestId||null,
        actorUserId:user.id,
        execute:false
      });
      return NextResponse.json({ok:true,result},{headers:{'Cache-Control':'no-store'}});
    }

    if(action==='execute'){
      if(!owner(user))return NextResponse.json({ok:false,error:'owner_required'},{status:403});
      if(String(body?.confirmCandidateId||'')!==candidateId){
        return NextResponse.json({ok:false,error:'candidate_confirmation_required'},{status:409});
      }
      if(!uuid(body?.privacyRequestId)){
        return NextResponse.json({ok:false,error:'privacy_request_id_required'},{status:400});
      }
      const result=await executeCandidateDeletion({
        agencyId:user.agency_id,
        candidateId,
        privacyRequestId:body.privacyRequestId,
        actorUserId:user.id,
        execute:true
      });
      return NextResponse.json({ok:result?.ok===true,result},{status:result?.blocked?409:result?.ok?200:422,headers:{'Cache-Control':'no-store'}});
    }

    return NextResponse.json({ok:false,error:'unsupported_action'},{status:400});
  }catch(error){
    console.error('privacy_request_operation_failed',error?.message||'');
    return NextResponse.json({ok:false,error:'privacy_request_operation_failed'},{status:503});
  }
}
