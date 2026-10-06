import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { mutationRequestIsTrusted, declaredBodyWithin } from '@/lib/request-security';
import { queryPath, serviceRequest } from '@/lib/service-store';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function admin(user){return user?.id&&user?.agency_id&&['OWNER','ADMIN'].includes(String(user.role||'').toUpperCase())}
function httpsOrNull(value){
  const raw=String(value||'').trim();
  if(!raw)return null;
  const url=new URL(raw);
  if(url.protocol!=='https:')throw new Error('privacy_notice_url_https_required');
  return url.toString();
}

export async function GET(){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  try{
    const rows=await serviceRequest(queryPath('organization_data_governance',{
      select:'agency_id,candidate_privacy_notice_version,candidate_privacy_notice_url,candidate_privacy_notice_text,candidate_ai_notice_text,candidate_notice_effective_at,updated_at',
      agency_id:`eq.${user.agency_id}`,
      limit:'1'
    }));
    return NextResponse.json({ok:true,notice:Array.isArray(rows)?rows[0]||null:null},{headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    return NextResponse.json({ok:false,error:'privacy_notice_unavailable'},{status:503});
  }
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,64*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!admin(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  let body;try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  try{
    const version=String(body?.version||'').trim().slice(0,80)||null;
    const noticeText=String(body?.noticeText||'').trim().slice(0,20_000)||null;
    const aiNoticeText=String(body?.aiNoticeText||'').trim().slice(0,20_000)||null;
    const noticeUrl=httpsOrNull(body?.noticeUrl);
    if(version&&(!noticeText&&!noticeUrl))return NextResponse.json({ok:false,error:'notice_content_required'},{status:400});
    const effectiveAt=body?.effectiveAt?new Date(body.effectiveAt).toISOString():new Date().toISOString();
    const rows=await serviceRequest('/rest/v1/organization_data_governance?on_conflict=agency_id',{
      method:'POST',
      body:{
        agency_id:user.agency_id,
        candidate_privacy_notice_version:version,
        candidate_privacy_notice_url:noticeUrl,
        candidate_privacy_notice_text:noticeText,
        candidate_ai_notice_text:aiNoticeText,
        candidate_notice_effective_at:version?effectiveAt:null,
        updated_by_user_id:user.id,
        updated_at:new Date().toISOString()
      },
      prefer:'resolution=merge-duplicates,return=representation'
    });
    await serviceRequest('/rest/v1/audit_events',{
      method:'POST',
      body:{
        id:crypto.randomUUID(),
        agency_id:user.agency_id,
        actor_user_id:user.id,
        action:'privacy.notice_updated',
        entity_type:'agency',
        entity_id:user.agency_id,
        metadata:{version,notice_url:noticeUrl,ai_notice_present:Boolean(aiNoticeText),effective_at:version?effectiveAt:null}
      },
      prefer:'return=minimal'
    });
    return NextResponse.json({ok:true,notice:Array.isArray(rows)?rows[0]||null:null},{headers:{'Cache-Control':'no-store'}});
  }catch(error){
    const status=error?.message==='privacy_notice_url_https_required'?400:503;
    return NextResponse.json({ok:false,error:error?.message==='privacy_notice_url_https_required'?error.message:'privacy_notice_update_failed'},{status});
  }
}
