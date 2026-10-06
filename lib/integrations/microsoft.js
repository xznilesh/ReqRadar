import { getIntegrationConnection, updateIntegrationHealth, upsertIntegrationConnection } from './store.js';

const PROVIDER='MICROSOFT';
const GRAPH='https://graph.microsoft.com/v1.0';
export const MICROSOFT_SCOPES=['openid','profile','email','offline_access','User.Read','Mail.Read','Mail.Send','Calendars.ReadWrite'];

function config(){
  const clientId=String(process.env.MICROSOFT_CLIENT_ID||'').trim();
  const clientSecret=String(process.env.MICROSOFT_CLIENT_SECRET||'').trim();
  const tenant=String(process.env.MICROSOFT_TENANT_ID||'common').trim()||'common';
  if(!clientId||!clientSecret)throw new Error('microsoft_oauth_not_configured');
  return {clientId,clientSecret,tenant};
}
function form(data){return new URLSearchParams(Object.entries(data).filter(([,v])=>v!==undefined&&v!==null).map(([k,v])=>[k,String(v)]))}
async function jsonResponse(response,label){
  const data=await response.json().catch(()=>null);
  if(!response.ok){const error=new Error(label);error.status=response.status;error.details=data;throw error}
  return data;
}

export function microsoftAuthorizationUrl({redirectUri,state,challenge}){
  const {clientId,tenant}=config();
  const url=new URL(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/authorize`);
  for(const [key,value] of Object.entries({
    client_id:clientId,response_type:'code',redirect_uri:redirectUri,response_mode:'query',
    scope:MICROSOFT_SCOPES.join(' '),state,code_challenge:challenge,code_challenge_method:'S256',prompt:'select_account'
  }))url.searchParams.set(key,value);
  return url.toString();
}

export async function exchangeMicrosoftCode({code,redirectUri,verifier}){
  const {clientId,clientSecret,tenant}=config();
  const response=await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`,{
    method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},
    body:form({client_id:clientId,client_secret:clientSecret,code,redirect_uri:redirectUri,grant_type:'authorization_code',code_verifier:verifier,scope:MICROSOFT_SCOPES.join(' ')}),
    cache:'no-store'
  });
  return jsonResponse(response,'microsoft_oauth_code_exchange_failed');
}

export async function refreshMicrosoftAccessToken(refreshToken){
  const {clientId,clientSecret,tenant}=config();
  if(!refreshToken)throw new Error('microsoft_refresh_token_missing');
  const response=await fetch(`https://login.microsoftonline.com/${encodeURIComponent(tenant)}/oauth2/v2.0/token`,{
    method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},
    body:form({client_id:clientId,client_secret:clientSecret,refresh_token:refreshToken,grant_type:'refresh_token',scope:MICROSOFT_SCOPES.join(' ')}),
    cache:'no-store'
  });
  return jsonResponse(response,'microsoft_oauth_refresh_failed');
}

async function graphRaw(accessToken,path,{method='GET',body}={}){
  const response=await fetch(GRAPH+path,{
    method,
    headers:{authorization:`Bearer ${accessToken}`,accept:'application/json',...(body!==undefined?{'content-type':'application/json'}:{})},
    ...(body!==undefined?{body:JSON.stringify(body)}:{}),
    cache:'no-store'
  });
  if(response.status===204)return {};
  return jsonResponse(response,'microsoft_graph_failed');
}

export async function microsoftUserInfo(accessToken){
  return graphRaw(accessToken,'/me?$select=id,displayName,mail,userPrincipalName');
}

export async function persistMicrosoftConnection({agencyId,userId,tokens,profile}){
  const expiresAt=tokens?.expires_in?new Date(Date.now()+Number(tokens.expires_in)*1000).toISOString():null;
  return upsertIntegrationConnection({
    agencyId,userId,provider:PROVIDER,
    externalAccountId:profile?.id||null,
    externalAccountEmail:profile?.mail||profile?.userPrincipalName||null,
    accessToken:tokens?.access_token||null,
    refreshToken:tokens?.refresh_token||null,
    tokenExpiresAt:expiresAt,
    scopes:String(tokens?.scope||MICROSOFT_SCOPES.join(' ')).split(/\s+/).filter(Boolean),
    status:'CONNECTED'
  });
}

async function connectionWithFreshToken({agencyId,userId}){
  let connection=await getIntegrationConnection({agencyId,userId,provider:PROVIDER});
  if(!connection||connection.status==='REVOKED')throw new Error('microsoft_not_connected');
  const exp=connection.token_expires_at?Date.parse(connection.token_expires_at):0;
  if(connection.accessToken&&(!exp||exp>Date.now()+60_000))return connection;
  try{
    const refreshed=await refreshMicrosoftAccessToken(connection.refreshToken);
    await persistMicrosoftConnection({agencyId,userId,tokens:refreshed,profile:{id:connection.external_account_id,mail:connection.external_account_email}});
    connection=await getIntegrationConnection({agencyId,userId,provider:PROVIDER});
    return connection;
  }catch(error){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:'refresh_failed'}).catch(()=>null);
    throw error;
  }
}

async function graphApi({agencyId,userId,path,method='GET',body}){
  const connection=await connectionWithFreshToken({agencyId,userId});
  try{
    const data=await graphRaw(connection.accessToken,path,{method,body});
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:true}).catch(()=>null);
    return data;
  }catch(error){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:error?.status===401?'unauthorized':`http_${error?.status||0}`}).catch(()=>null);
    if(error?.status===401)throw new Error('microsoft_reauth_required');
    throw error;
  }
}

export async function microsoftHealth({agencyId,userId}){
  try{
    const connection=await connectionWithFreshToken({agencyId,userId});
    const profile=await microsoftUserInfo(connection.accessToken);
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:true});
    return {provider:'MICROSOFT',ok:true,email:profile?.mail||profile?.userPrincipalName||connection.external_account_email||null};
  }catch(error){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:error?.message||'health_failed'}).catch(()=>null);
    return {provider:'MICROSOFT',ok:false,error:error?.message||'health_failed'};
  }
}

export async function microsoftSendEmail({agencyId,userId,to,subject,textBody}){
  const recipients=String(to||'').split(',').map(v=>v.trim()).filter(Boolean).slice(0,50).map(address=>({emailAddress:{address}}));
  if(!recipients.length)throw new Error('email_recipient_required');
  const message={
    subject:String(subject||'').replace(/[\r\n]+/g,' ').slice(0,300),
    body:{contentType:'Text',content:String(textBody||'').slice(0,200_000)},
    toRecipients:recipients
  };
  await graphApi({agencyId,userId,path:'/me/sendMail',method:'POST',body:{message,saveToSentItems:true}});
  return {ok:true};
}

export async function microsoftRecentMessages({agencyId,userId,maxResults=20}){
  const limit=Math.max(1,Math.min(Number(maxResults)||20,50));
  const data=await graphApi({agencyId,userId,path:`/me/messages?$top=${limit}&$orderby=receivedDateTime%20desc&$select=id,subject,from,toRecipients,receivedDateTime,bodyPreview,isRead`});
  return Array.isArray(data?.value)?data.value:[];
}

export async function microsoftCalendarEvents({agencyId,userId,startDateTime=new Date().toISOString(),endDateTime=null,maxResults=50}){
  const start=new Date(startDateTime).toISOString();
  const end=new Date(endDateTime||Date.now()+30*24*60*60*1000).toISOString();
  const limit=Math.max(1,Math.min(Number(maxResults)||50,100));
  const path=`/me/calendarView?startDateTime=${encodeURIComponent(start)}&endDateTime=${encodeURIComponent(end)}&$top=${limit}&$orderby=start/dateTime&$select=id,subject,start,end,location,attendees,webLink`;
  const data=await graphApi({agencyId,userId,path});
  return Array.isArray(data?.value)?data.value:[];
}

export async function microsoftCreateCalendarEvent({agencyId,userId,event}){
  const payload={
    subject:String(event?.summary||event?.subject||'Interview').slice(0,300),
    body:{contentType:'Text',content:String(event?.description||'').slice(0,10_000)},
    start:event?.start,
    end:event?.end,
    location:event?.location?{displayName:String(event.location).slice(0,500)}:undefined,
    attendees:Array.isArray(event?.attendees)?event.attendees.slice(0,100).map(item=>({
      emailAddress:{address:String(item?.email||item).trim().toLowerCase()},type:'required'
    })).filter(x=>x.emailAddress.address):undefined
  };
  if(!payload.start?.dateTime||!payload.end?.dateTime)throw new Error('calendar_start_end_required');
  return graphApi({agencyId,userId,path:'/me/events',method:'POST',body:payload});
}
