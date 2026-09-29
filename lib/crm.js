import { sessionToken } from '@/lib/auth';
import { rpc } from '@/lib/supabase-api';

async function dispatch(action,payload={}){
  const token=await sessionToken();
  if(!token)return {ok:false,error:'unauthorized'};
  return rpc('xzrecruiter_crm_dispatch',{p_token:token,p_action:action,p_payload:payload||{}});
}

export async function getCrmReferenceContext(){
  const result=await dispatch('referenceContext');
  return result?.ok?result:null;
}

export async function getCrmSearch(module,query='',filters={},limit=50,offset=0){
  const result=await dispatch('search',{module,query,filters:filters||{},limit,offset});
  return result?.ok?result:null;
}

export async function getBusinessPipeline(limit=500){
  const result=await dispatch('businessPipeline',{limit});
  return result?.ok?result:null;
}

export async function getVendorContext(query='',limit=50,offset=0){
  const result=await dispatch('vendorContext',{query,limit,offset});
  return result?.ok?result:null;
}

export async function crmAction(name,args={}){
  if(name==='clientStaffingContext'){
    const token=await sessionToken();if(!token)return {ok:false,error:'unauthorized'};
    return rpc('xzrecruiter_client_staffing_context',{p_token:token,p_client_id:args.clientId});
  }
  if(name==='setAccountParent'){
    const token=await sessionToken();if(!token)return {ok:false,error:'unauthorized'};
    return rpc('xzrecruiter_set_account_parent',{p_token:token,p_client_id:args.clientId,p_parent_client_id:args.parentClientId||null,p_expected_updated_at:args.expectedUpdatedAt||null});
  }
  const allowed=new Set([
    'saveClient','saveContact','saveOpportunity','moveOpportunity','saveActivity','saveTask',
    'setTaskStatus','saveContract','saveCustomValues','client360','contact360','opportunity360',
    'archiveEntity','saveSavedView','savedViewContext','issueClientPortal','saveVendor',
    'issueVendorPortal','shareJobVendor'
  ]);
  if(!allowed.has(name))return {ok:false,error:'unsupported_action'};
  return dispatch(name,args||{});
}

export async function getCrmSavedViews(module){
  const result=await crmAction('savedViewContext',{module});
  return result?.ok?(result.views||[]):[];
}
