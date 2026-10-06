import { NextResponse } from 'next/server';
import { authenticateScimRequest, deactivateScimUser, getScimUser, patchScimUser, scimError } from '@/lib/scim';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function reply(body,status=200){
  return NextResponse.json(body,{status,headers:{'Content-Type':'application/scim+json','Cache-Control':'private, no-store'}});
}

async function idFrom(context){
  const params=await context.params;
  return String(params?.id||'');
}

export async function GET(req,context){
  try{
    const auth=await authenticateScimRequest(req);
    const resource=await getScimUser({agencyId:auth.agencyId,userId:await idFrom(context)});
    if(!resource)return reply(scimError('not_found',404).body,404);
    return reply(resource);
  }catch(error){
    const out=scimError(error);
    return reply(out.body,out.status);
  }
}

export async function PATCH(req,context){
  try{
    const auth=await authenticateScimRequest(req);
    const declared=Number(req.headers.get('content-length')||0);
    if(declared>64*1024)return reply(scimError('request_too_large',413).body,413);
    const payload=await req.json();
    const resource=await patchScimUser({agencyId:auth.agencyId,userId:await idFrom(context),payload});
    if(!resource)return reply(scimError('not_found',404).body,404);
    return reply(resource);
  }catch(error){
    const out=scimError(error);
    return reply(out.body,out.status);
  }
}

export async function DELETE(req,context){
  try{
    const auth=await authenticateScimRequest(req);
    const resource=await deactivateScimUser({agencyId:auth.agencyId,userId:await idFrom(context)});
    if(!resource)return reply(scimError('not_found',404).body,404);
    return new NextResponse(null,{status:204,headers:{'Cache-Control':'private, no-store'}});
  }catch(error){
    const out=scimError(error);
    return reply(out.body,out.status);
  }
}
