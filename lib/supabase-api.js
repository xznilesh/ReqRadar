const SUPABASE_URL=String(
  process.env.XZRECRUITER_SUPABASE_URL||
  process.env.NEXT_PUBLIC_SUPABASE_URL||
  ''
).trim().replace(/\/$/,'');
const SUPABASE_PUBLISHABLE_KEY=String(
  process.env.XZRECRUITER_SUPABASE_PUBLISHABLE_KEY||
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY||
  ''
).trim();

export function supabaseConfigured(){
  return /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(SUPABASE_URL)&&Boolean(SUPABASE_PUBLISHABLE_KEY);
}
function requireSupabaseConfig(){
  if(!supabaseConfigured())throw new Error('xzrecruiter_supabase_not_configured');
}
async function parseResponse(response){
  const text=await response.text();
  if(!text)return null;
  try{return JSON.parse(text)}catch{return text}
}

export async function rpc(name,args={},options={}){
  requireSupabaseConfig();
  const headers={apikey:SUPABASE_PUBLISHABLE_KEY,'content-type':'application/json',accept:'application/json'};
  if(options.accessToken)headers.authorization=`Bearer ${options.accessToken}`;
  const response=await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`,{
    method:'POST',headers,body:JSON.stringify(args),cache:'no-store'
  });
  const data=await parseResponse(response);
  if(!response.ok){
    const error=new Error(`Supabase RPC ${name} failed with HTTP ${response.status}`);
    error.status=response.status;error.details=data;throw error;
  }
  return data;
}

export async function requestEmailProof(email,redirectTo){
  requireSupabaseConfig();
  const url=new URL(`${SUPABASE_URL}/auth/v1/otp`);
  if(redirectTo)url.searchParams.set('redirect_to',redirectTo);
  const response=await fetch(url,{
    method:'POST',
    headers:{apikey:SUPABASE_PUBLISHABLE_KEY,'content-type':'application/json'},
    body:JSON.stringify({email:String(email||'').trim().toLowerCase(),create_user:true}),
    cache:'no-store'
  });
  const data=await parseResponse(response);
  if(!response.ok){
    const error=new Error(`Verification email request failed with HTTP ${response.status}`);
    error.status=response.status;error.details=data;throw error;
  }
  return data;
}

export async function getAuthUser(accessToken){
  requireSupabaseConfig();
  const response=await fetch(`${SUPABASE_URL}/auth/v1/user`,{
    headers:{apikey:SUPABASE_PUBLISHABLE_KEY,authorization:`Bearer ${accessToken}`,accept:'application/json'},
    cache:'no-store'
  });
  const data=await parseResponse(response);
  if(!response.ok){
    const error=new Error(`Supabase Auth user lookup failed with HTTP ${response.status}`);
    error.status=response.status;error.details=data;throw error;
  }
  return data;
}

export {SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY};
