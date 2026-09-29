import { createHash } from 'node:crypto';
import { NextResponse } from 'next/server';
import { declaredBodyWithin,mutationRequestIsTrusted,safeRequestId } from '@/lib/request-security';
import { getStaffingAnalytics,getAutomationNotifications,getManagerAnalytics,getManagerControlCenter,getManagerRequirement,managerControlAction } from '@/lib/manager-control-server';
import { serviceRpc } from '@/lib/server-rpc';

export const runtime='nodejs';
export const dynamic='force-dynamic';

const MAX_BODY=32768;
function uuid(v){return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(v||''))}
function fail(error,status=400,requestId){return NextResponse.json({ok:false,error,requestId},{status})}
function errorStatus(error){
  if(error==='forbidden')return 403;
  if(['job_not_found','application_not_found','assignment_not_found'].includes(error))return 404;
  if(['requirement_not_operational','invalid_requirement_transition','client_submission_required'].includes(error))return 422;
  if(error==='idempotency_key_required')return 400;
  return 400;
}
function clientKey(req){return createHash('sha256').update(String(req.headers.get('x-forwarded-for')||req.headers.get('x-real-ip')||'unknown').split(',')[0].trim()).digest('hex')}
async function limited(req,scope,limit,seconds){
  try{
    const r=await serviceRpc('xzrecruiter_consume_rate_limit',{p_scope:scope,p_key_hash:clientKey(req),p_limit:limit,p_window_seconds:seconds});
    return r?.allowed!==false;
  }catch{return true}
}

export async function GET(req){
  const requestId=safeRequestId(req);
  const mode=req.nextUrl.searchParams.get('mode')||'home';
  try{
    if(mode==='staffingAnalytics'){
      const args=Object.fromEntries(['from','to','clientId','recruiterId','accountManagerId'].map(k=>[k,req.nextUrl.searchParams.get(k)||null]));
      if(['clientId','recruiterId','accountManagerId'].some(k=>args[k]&&!uuid(args[k])))return fail('invalid_filter',400,requestId);
      const data=await getStaffingAnalytics(args);return data?.ok?NextResponse.json(data):fail(data?.error||'staffing_unavailable',data?.error==='forbidden'?403:400,requestId);
    }
    if(mode==='home'){
      const data=await getManagerControlCenter(50);return data?NextResponse.json({...data,requestId}):fail('forbidden_or_unavailable',403,requestId);
    }
    if(mode==='notifications'){
      const data=await getAutomationNotifications(75);return data?NextResponse.json({...data,requestId}):fail('forbidden_or_unavailable',403,requestId);
    }
    if(mode==='requirement'){
      const jobId=req.nextUrl.searchParams.get('jobId')||'';if(!uuid(jobId))return fail('invalid_job',400,requestId);
      const data=await getManagerRequirement(jobId);return data?NextResponse.json({...data,requestId}):fail('forbidden_or_unavailable',403,requestId);
    }
    if(mode==='analytics'){
      const from=req.nextUrl.searchParams.get('from')||null,to=req.nextUrl.searchParams.get('to')||null;
      const clientId=req.nextUrl.searchParams.get('clientId')||null,jobId=req.nextUrl.searchParams.get('jobId')||null,recruiterId=req.nextUrl.searchParams.get('recruiterId')||null;
      const accountManagerId=req.nextUrl.searchParams.get('accountManagerId')||null;
      if(clientId&&!uuid(clientId)||jobId&&!uuid(jobId)||recruiterId&&!uuid(recruiterId)||accountManagerId&&!uuid(accountManagerId))return fail('invalid_filter',400,requestId);
      const data=await getManagerAnalytics({from,to,clientId,jobId,recruiterId,accountManagerId,source:req.nextUrl.searchParams.get('source')||null});
      return data?NextResponse.json({...data,requestId}):fail('forbidden_or_unavailable',403,requestId);
    }
    return fail('unsupported_mode',400,requestId);
  }catch(error){
    console.error('manager_control_get_failed',{requestId,mode,error:error?.message||'unknown'});
    return fail('manager_control_unavailable',500,requestId);
  }
}

export async function POST(req){
  const requestId=safeRequestId(req);
  if(!mutationRequestIsTrusted(req))return fail('invalid_request_origin',403,requestId);
  if(!declaredBodyWithin(req,MAX_BODY))return fail('request_too_large',413,requestId);
  let body;try{body=await req.json()}catch{return fail('invalid_json',400,requestId)}
  const action=String(body?.action||'');
  try{
    if(action==='manualRun'){
      if(!(await limited(req,'step8-manual-run',10,3600)))return fail('rate_limited',429,requestId);
      const result=await managerControlAction('manualRun');return result?.ok?NextResponse.json({...result,requestId}):fail(result?.error||'run_failed',errorStatus(result?.error),requestId);
    }
    if(action==='alertAction'){
      if(!uuid(body?.alertId)||!['ACKNOWLEDGE','DISMISS'].includes(String(body?.alertAction||'').toUpperCase()))return fail('invalid_alert_action',400,requestId);
      const result=await managerControlAction('alertAction',{alertId:body.alertId,alertAction:String(body.alertAction).toUpperCase()});
      return result?.ok?NextResponse.json({...result,requestId}):fail(result?.error||'alert_action_failed',errorStatus(result?.error),requestId);
    }
    if(action==='managerAction'){
      const allowed=new Set(['SET_PRIORITY','HOLD_REQUIREMENT','REOPEN_REQUIREMENT','ASSIGN_RECRUITER','SET_RECRUITER_TARGET','CREATE_MANAGER_TASK','ACKNOWLEDGE_BLOCKER']);
      const managerAction=String(body?.managerAction||'').toUpperCase();if(!allowed.has(managerAction))return fail('invalid_manager_action',400,requestId);
      const payload=body?.payload&&typeof body.payload==='object'?body.payload:{};
      if(!uuid(payload.jobId))return fail('invalid_job',400,requestId);
      if(managerAction==='CREATE_MANAGER_TASK'&&!String(payload.idempotencyKey||'').trim())return fail('idempotency_key_required',400,requestId);
      for(const key of ['recruiterUserId','assignedUserId'])if(payload[key]&&!uuid(payload[key]))return fail('invalid_user',400,requestId);
      const result=await managerControlAction('managerAction',{managerAction,payload});
      return result?.ok?NextResponse.json({...result,requestId}):fail(result?.error||'manager_action_failed',errorStatus(result?.error),requestId);
    }
    if(action==='clientFeedback'){
      if(!uuid(body?.applicationId))return fail('invalid_application',400,requestId);
      const result=await managerControlAction('clientFeedback',{applicationId:body.applicationId,feedback:String(body.feedback||'').slice(0,1500),outcome:String(body.outcome||'').slice(0,100)});
      return result?.ok?NextResponse.json({...result,requestId}):fail(result?.error||'feedback_failed',errorStatus(result?.error),requestId);
    }
    return fail('unsupported_action',400,requestId);
  }catch(error){
    console.error('manager_control_post_failed',{requestId,action,error:error?.message||'unknown'});
    return fail('manager_control_unavailable',500,requestId);
  }
}
