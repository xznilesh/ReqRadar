import { NextResponse } from 'next/server';
import { getCurrentUser, sessionToken } from '@/lib/auth';
import { declaredBodyWithin, mutationRequestIsTrusted } from '@/lib/request-security';
import {
  adminSessionStoreConfigured,
  currentWorkspaceSessionId,
  listWorkspaceSessions,
  revokeWorkspaceSession
} from '@/lib/admin-sessions';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function adminContext(user){
  if(!user?.id||!user?.agency_id)return null;
  const role=String(user.role||'').trim().toUpperCase();
  if(!['OWNER','ADMIN'].includes(role))return null;
  return {userId:user.id,agencyId:user.agency_id,role};
}

export async function GET(){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  const admin=adminContext(user);
  if(!admin)return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  if(!adminSessionStoreConfigured())return NextResponse.json({ok:false,error:'session_admin_unavailable'},{status:503});

  try{
    const token=await sessionToken();
    const currentSessionId=await currentWorkspaceSessionId({agencyId:admin.agencyId,token});
    const sessions=await listWorkspaceSessions({agencyId:admin.agencyId,currentSessionId,limit:200});
    return NextResponse.json({
      ok:true,
      sessions,
      capabilities:{
        targeted_revoke:true,
        workspace_scoped:true,
        device_metadata:true
      }
    },{headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    console.error('admin_session_list_failed',error?.status||'',error?.message||'');
    return NextResponse.json({ok:false,error:'session_admin_unavailable'},{status:503});
  }
}

export async function POST(req){
  if(!mutationRequestIsTrusted(req))return NextResponse.json({ok:false,error:'invalid_origin'},{status:403});
  if(!declaredBodyWithin(req,16*1024))return NextResponse.json({ok:false,error:'request_too_large'},{status:413});

  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  const admin=adminContext(user);
  if(!admin)return NextResponse.json({ok:false,error:'forbidden'},{status:403});
  if(!adminSessionStoreConfigured())return NextResponse.json({ok:false,error:'session_admin_unavailable'},{status:503});

  let body;
  try{body=await req.json()}catch{return NextResponse.json({ok:false,error:'invalid_json'},{status:400})}
  const sessionId=String(body?.sessionId||'');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sessionId)){
    return NextResponse.json({ok:false,error:'invalid_session_id'},{status:400});
  }

  try{
    const result=await revokeWorkspaceSession({
      agencyId:admin.agencyId,
      sessionId,
      actorUserId:admin.userId
    });
    if(!result.ok)return NextResponse.json(result,{status:404});
    return NextResponse.json(result,{headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    console.error('admin_session_revoke_failed',error?.status||'',error?.message||'');
    return NextResponse.json({ok:false,error:'session_revoke_failed'},{status:503});
  }
}
