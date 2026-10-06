import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { googleHealth } from '@/lib/integrations/google';
import { microsoftHealth } from '@/lib/integrations/microsoft';

export const runtime='nodejs';
export const dynamic='force-dynamic';

export async function GET(){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  const [google,microsoft]=await Promise.all([
    googleHealth({agencyId:user.agency_id,userId:user.id}),
    microsoftHealth({agencyId:user.agency_id,userId:user.id})
  ]);
  return NextResponse.json({ok:true,connections:{google,microsoft}},{headers:{'Cache-Control':'private, no-store'}});
}
