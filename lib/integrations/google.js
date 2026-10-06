import { getIntegrationConnection, updateIntegrationHealth, upsertIntegrationConnection } from './store.js';

const PROVIDER='GOOGLE';
const AUTH_URL='https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL='https://oauth2.googleapis.com/token';
const USERINFO_URL='https://www.googleapis.com/oauth2/v3/userinfo';
const GMAIL='https://gmail.googleapis.com/gmail/v1';
const CALENDAR='https://www.googleapis.com/calendar/v3';
export const GOOGLE_SCOPES=[
  'openid','email','profile',
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send',
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/calendar.events'
];

function config(){
  const clientId=String(process.env.GOOGLE_CLIENT_ID||'').trim();
  const clientSecret=String(process.env.GOOGLE_CLIENT_SECRET||'').trim();
  if(!clientId||!clientSecret)throw new Error('google_oauth_not_configured');
  return {clientId,clientSecret};
}
function form(data){return new URLSearchParams(Object.entries(data).filter(([,v])=>v!==undefined&&v!==null).map(([k,v])=>[k,String(v)]))}
async function jsonResponse(response,label){
  const data=await response.json().catch(()=>null);
  if(!response.ok){
    const error=new Error(label);
    error.status=response.status;error.details=data;throw error;
  }
  return data;
}
function safeHeader(value,max=500){
  const v=String(value||'').replace(/[\r\n]+/g,' ').trim().slice(0,max);
  if(!v)throw new Error('email_header_required');
  return v;
}
function base64url(value){return Buffer.from(String(value),'utf8').toString('base64url')}

export function googleAuthorizationUrl({redirectUri,state,challenge}){
  const {clientId}=config();
  const url=new URL(AUTH_URL);
  for(const [key,value] of Object.entries({
    client_id:clientId,redirect_uri:redirectUri,response_type:'code',
    scope:GOOGLE_SCOPES.join(' '),access_type:'offline',include_granted_scopes:'true',
    prompt:'consent',state,code_challenge:challenge,code_challenge_method:'S256'
  }))url.searchParams.set(key,value);
  return url.toString();
}

export async function exchangeGoogleCode({code,redirectUri,verifier}){
  const {clientId,clientSecret}=config();
  const response=await fetch(TOKEN_URL,{
    method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},
    body:form({client_id:clientId,client_secret:clientSecret,code,grant_type:'authorization_code',redirect_uri:redirectUri,code_verifier:verifier}),
    cache:'no-store'
  });
  return jsonResponse(response,'google_oauth_code_exchange_failed');
}

export async function refreshGoogleAccessToken(refreshToken){
  const {clientId,clientSecret}=config();
  if(!refreshToken)throw new Error('google_refresh_token_missing');
  const response=await fetch(TOKEN_URL,{
    method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},
    body:form({client_id:clientId,client_secret:clientSecret,refresh_token:refreshToken,grant_type:'refresh_token'}),
    cache:'no-store'
  });
  return jsonResponse(response,'google_oauth_refresh_failed');
}

export async function googleUserInfo(accessToken){
  const response=await fetch(USERINFO_URL,{headers:{authorization:`Bearer ${accessToken}`,accept:'application/json'},cache:'no-store'});
  return jsonResponse(response,'google_userinfo_failed');
}

export async function persistGoogleConnection({agencyId,userId,tokens,profile}){
  const expiresAt=tokens?.expires_in?new Date(Date.now()+Number(tokens.expires_in)*1000).toISOString():null;
  return upsertIntegrationConnection({
    agencyId,userId,provider:PROVIDER,
    externalAccountId:profile?.sub||null,
    externalAccountEmail:profile?.email||null,
    accessToken:tokens?.access_token||null,
    refreshToken:tokens?.refresh_token||null,
    tokenExpiresAt:expiresAt,
    scopes:String(tokens?.scope||GOOGLE_SCOPES.join(' ')).split(/\s+/).filter(Boolean),
    status:'CONNECTED'
  });
}

async function connectionWithFreshToken({agencyId,userId}){
  let connection=await getIntegrationConnection({agencyId,userId,provider:PROVIDER});
  if(!connection||connection.status==='REVOKED')throw new Error('google_not_connected');
  const exp=connection.token_expires_at?Date.parse(connection.token_expires_at):0;
  if(connection.accessToken&&(!exp||exp>Date.now()+60_000))return connection;
  try{
    const refreshed=await refreshGoogleAccessToken(connection.refreshToken);
    await persistGoogleConnection({agencyId,userId,tokens:refreshed,profile:{sub:connection.external_account_id,email:connection.external_account_email}});
    connection=await getIntegrationConnection({agencyId,userId,provider:PROVIDER});
    return connection;
  }catch(error){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:'refresh_failed'}).catch(()=>null);
    throw error;
  }
}

async function googleApi({agencyId,userId,url,method='GET',body,headers={}}){
  const connection=await connectionWithFreshToken({agencyId,userId});
  const response=await fetch(url,{
    method,
    headers:{authorization:`Bearer ${connection.accessToken}`,accept:'application/json',...(body!==undefined?{'content-type':'application/json'}:{}),...headers},
    ...(body!==undefined?{body:JSON.stringify(body)}:{}),
    cache:'no-store'
  });
  if(response.status===401){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:'unauthorized'}).catch(()=>null);
    throw new Error('google_reauth_required');
  }
  const data=await response.json().catch(()=>null);
  if(!response.ok){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:`http_${response.status}`}).catch(()=>null);
    const error=new Error('google_api_failed');error.status=response.status;error.details=data;throw error;
  }
  await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:true}).catch(()=>null);
  return data;
}

export async function googleHealth({agencyId,userId}){
  try{
    const connection=await connectionWithFreshToken({agencyId,userId});
    const profile=await googleUserInfo(connection.accessToken);
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:true});
    return {provider:'GOOGLE',ok:true,email:profile?.email||connection.external_account_email||null};
  }catch(error){
    await updateIntegrationHealth({agencyId,userId,provider:PROVIDER,ok:false,errorCode:error?.message||'health_failed'}).catch(()=>null);
    return {provider:'GOOGLE',ok:false,error:error?.message||'health_failed'};
  }
}

export async function googleSendEmail({agencyId,userId,to,subject,textBody}){
  const recipient=safeHeader(to,320), title=safeHeader(subject,300);
  const body=String(textBody||'').slice(0,200_000);
  const mime=[`To: ${recipient}`,`Subject: ${title}`,'MIME-Version: 1.0','Content-Type: text/plain; charset=UTF-8','',body].join('\r\n');
  return googleApi({agencyId,userId,url:`${GMAIL}/users/me/messages/send`,method:'POST',body:{raw:base64url(mime)}});
}

export async function googleRecentMessages({agencyId,userId,maxResults=20}){
  const limit=Math.max(1,Math.min(Number(maxResults)||20,50));
  const list=await googleApi({agencyId,userId,url:`${GMAIL}/users/me/messages?maxResults=${limit}&q=${encodeURIComponent('newer_than:30d')}`});
  const ids=Array.isArray(list?.messages)?list.messages.slice(0,limit):[];
  const messages=[];
  for(const item of ids){
    const message=await googleApi({agencyId,userId,url:`${GMAIL}/users/me/messages/${encodeURIComponent(item.id)}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date`});
    const headers=Object.fromEntries((message?.payload?.headers||[]).map(h=>[String(h.name||'').toLowerCase(),h.value]));
    messages.push({id:message.id,threadId:message.threadId,from:headers.from||null,to:headers.to||null,subject:headers.subject||null,date:headers.date||null,snippet:message.snippet||''});
  }
  return messages;
}

export async function googleCalendarEvents({agencyId,userId,timeMin=new Date().toISOString(),maxResults=50}){
  const limit=Math.max(1,Math.min(Number(maxResults)||50,100));
  const url=`${CALENDAR}/calendars/primary/events?singleEvents=true&orderBy=startTime&timeMin=${encodeURIComponent(timeMin)}&maxResults=${limit}`;
  const data=await googleApi({agencyId,userId,url});
  return Array.isArray(data?.items)?data.items:[];
}

export async function googleCreateCalendarEvent({agencyId,userId,event}){
  const payload={
    summary:String(event?.summary||'Interview').slice(0,300),
    description:String(event?.description||'').slice(0,10_000)||undefined,
    location:String(event?.location||'').slice(0,500)||undefined,
    start:event?.start,end:event?.end,
    attendees:Array.isArray(event?.attendees)?event.attendees.slice(0,100).map(item=>({email:String(item?.email||item).trim().toLowerCase()})).filter(x=>x.email):undefined
  };
  if(!payload.start||!payload.end)throw new Error('calendar_start_end_required');
  return googleApi({agencyId,userId,url:`${CALENDAR}/calendars/primary/events?sendUpdates=all`,method:'POST',body:payload});
}
