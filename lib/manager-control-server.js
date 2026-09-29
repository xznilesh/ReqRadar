import { sessionToken } from '@/lib/auth';
import { rpc } from '@/lib/supabase-api';

async function token(){return sessionToken()}

export async function getManagerControlCenter(limit=50){
  const p_token=await token();if(!p_token)return null;
  const result=await rpc('xzrecruiter_step8_manager_control_center',{p_token,p_limit:Number(limit||50)});
  return result?.ok?result:null;
}
export async function getManagerRequirement(jobId){
  const p_token=await token();if(!p_token)return null;
  const result=await rpc('xzrecruiter_step8_requirement_control',{p_token,p_job_id:jobId});
  return result?.ok?result:null;
}
export async function getManagerAnalytics(args={}){
  const p_token=await token();if(!p_token)return null;
  const result=await rpc('xzrecruiter_step8_analytics',{
    p_token,p_from:args.from||null,p_to:args.to||null,p_client:args.clientId||null,
    p_job:args.jobId||null,p_recruiter:args.recruiterId||null,p_account_manager:args.accountManagerId||null,
    p_source:args.source||null
  });
  return result?.ok?result:null;
}
export async function getAutomationNotifications(limit=50){
  const p_token=await token();if(!p_token)return null;
  const result=await rpc('xzrecruiter_step8_notification_center',{p_token,p_limit:Number(limit||50)});
  return result?.ok?result:null;
}
export async function managerControlAction(action,args={}){
  const p_token=await token();if(!p_token)return {ok:false,error:'unauthorized'};
  if(action==='manualRun')return rpc('xzrecruiter_run_step8_manual',{p_token});
  if(action==='alertAction')return rpc('xzrecruiter_step8_alert_action',{p_token,p_alert_id:args.alertId,p_action:args.alertAction});
  if(action==='managerAction')return rpc('xzrecruiter_step8_manager_action',{p_token,p_action:args.managerAction,p_payload:args.payload||{}});
  if(action==='clientFeedback')return rpc('xzrecruiter_step8_record_client_feedback',{p_token,p_application_id:args.applicationId,p_feedback:args.feedback||'',p_outcome:args.outcome||null});
  return {ok:false,error:'unsupported_action'};
}

export async function getStaffingAnalytics(args={}){
  const p_token=await token();if(!p_token)return null;
  return rpc('xzrecruiter_staffing_analytics',{p_token,p_from:args.from||null,p_to:args.to||null,p_client:args.clientId||null,p_recruiter:args.recruiterId||null,p_account_manager:args.accountManagerId||null});
}
