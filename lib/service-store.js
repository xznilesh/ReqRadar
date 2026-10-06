import { SUPABASE_URL } from './supabase-api.js';

const SERVICE_KEY=String(process.env.SUPABASE_SERVICE_ROLE_KEY||'').trim();

export function serviceStoreConfigured(){
  return /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(String(SUPABASE_URL||''))&&Boolean(SERVICE_KEY);
}

export function assertUuid(value,label='id'){
  const v=String(value||'');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v))throw new Error('invalid_'+label);
  return v;
}

export function queryPath(table,params={}){
  if(!/^[a-z][a-z0-9_]*$/i.test(String(table||'')))throw new Error('invalid_service_table');
  const q=new URLSearchParams();
  for(const [key,value] of Object.entries(params))if(value!==undefined&&value!==null)q.set(key,String(value));
  return `/rest/v1/${table}?${q.toString()}`;
}

export async function serviceRequest(path,{method='GET',body,prefer,headers={}}={}){
  if(!serviceStoreConfigured())throw new Error('service_store_not_configured');
  if(!String(path||'').startsWith('/rest/v1/'))throw new Error('invalid_service_path');
  const response=await fetch(SUPABASE_URL+path,{
    method,
    headers:{
      apikey:SERVICE_KEY,
      authorization:`Bearer ${SERVICE_KEY}`,
      accept:'application/json',
      ...(body!==undefined?{'content-type':'application/json'}:{}),
      ...(prefer?{prefer}:{}),
      ...headers
    },
    ...(body!==undefined?{body:JSON.stringify(body)}:{}),
    cache:'no-store'
  });
  const text=await response.text();
  let data=null;
  if(text){try{data=JSON.parse(text)}catch{data=text}}
  if(!response.ok){
    const error=new Error('service_store_request_failed');
    error.status=response.status;
    error.details=data;
    throw error;
  }
  return data;
}
