import { NextResponse } from 'next/server';
import { authenticateScimRequest, createScimUser, listScimUsers, scimError } from '@/lib/scim';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function reply(body,status=200){
  return NextResponse.json(body,{status,headers:{'Content-Type':'application/scim+json','Cache-Control':'private, no-store'}});
}

export async function GET(req){
  try{
    const auth=await authenticateScimRequest(req);
    const filter=req.nextUrl.searchParams.get('filter')||'';
    const startIndex=req.nextUrl.searchParams.get('startIndex')||'1';
    const count=req.nextUrl.searchParams.get('count')||'100';
    return reply(await listScimUsers({agencyId:auth.agencyId,filter,startIndex,count}));
  }catch(error){
    const out=scimError(error);
    return reply(out.body,out.status);
  }
}

export async function POST(req){
  try{
    const auth=await authenticateScimRequest(req);
    const declared=Number(req.headers.get('content-length')||0);
    if(declared>64*1024)return reply(scimError('request_too_large',413).body,413);
    const payload=await req.json();
    const resource=await createScimUser({agencyId:auth.agencyId,defaultRole:auth.defaultRole,payload});
    return reply(resource,201);
  }catch(error){
    const out=scimError(error);
    return reply(out.body,out.status);
  }
}
