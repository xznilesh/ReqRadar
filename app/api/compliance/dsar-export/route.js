import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { atsAction } from '@/lib/ats';
import { candidateConsentHistory } from '@/lib/compliance-data';

export const runtime='nodejs';
export const dynamic='force-dynamic';

function uuid(value){
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value||''));
}
function canExport(user){
  return ['OWNER','ADMIN'].includes(String(user?.role||'').trim().toUpperCase());
}

export async function GET(req){
  const user=await getCurrentUser().catch(()=>null);
  if(!user)return NextResponse.json({ok:false,error:'unauthorized'},{status:401});
  if(!canExport(user))return NextResponse.json({ok:false,error:'forbidden'},{status:403});

  const candidateId=String(req.nextUrl.searchParams.get('candidateId')||'');
  if(!uuid(candidateId))return NextResponse.json({ok:false,error:'invalid_candidate_id'},{status:400});

  try{
    const [profile,closeout,flatExport,consentHistory]=await Promise.all([
      atsAction('candidateProfileContext',{candidateId}),
      atsAction('candidateCloseout',{candidateId}),
      atsAction('candidateExport',{candidateIds:[candidateId]}),
      candidateConsentHistory({agencyId:user.agency_id,candidateId})
    ]);
    if(!profile?.ok){
      const status=profile?.error==='unauthorized'?401:profile?.error==='forbidden'?403:404;
      return NextResponse.json({ok:false,error:profile?.error||'candidate_not_found'},{status});
    }
    if(!closeout?.ok)return NextResponse.json({ok:false,error:closeout?.error||'candidate_context_unavailable'},{status:404});
    if(!flatExport?.ok)return NextResponse.json({ok:false,error:flatExport?.error||'candidate_export_forbidden'},{status:403});

    const candidate=profile.profile||{};
    const generatedAt=new Date().toISOString();
    const payload={
      ok:true,
      export_type:'DATA_SUBJECT_ACCESS',
      generated_at:generatedAt,
      generated_by:{user_id:user.id,role:user.role},
      subject:{type:'candidate',candidate_id:candidateId},
      candidate_profile:candidate,
      consent:{
        current_status:consentHistory.current?.status||candidate.consentStatus||'UNKNOWN',
        current_source:consentHistory.current?.source||candidate.consentSource||null,
        current_consent_at:consentHistory.current?.consent_at||null,
        history_available:consentHistory.history_available===true,
        events:consentHistory.events||[],
        scope_note:consentHistory.scope_note
      },
      retention:{
        current_status:candidate.retentionStatus||'ACTIVE',
        execution_certified:false,
        note:'Retention/deletion execution is not certified until the live migration/schema reconciliation and deletion drill pass.'
      },
      exportable_profile_rows:Array.isArray(flatExport.rows)?flatExport.rows:[],
      documents:Array.isArray(closeout.documents)?closeout.documents:[],
      parse_runs:Array.isArray(closeout.parse_runs)?closeout.parse_runs:[],
      recruitment_activity:Array.isArray(closeout.activity)?closeout.activity:[],
      merge_history:Array.isArray(closeout.merge_history)?closeout.merge_history:[],
      talent_pools:Array.isArray(closeout.talent_pools)?closeout.talent_pools:[],
      duplicate_signals:Array.isArray(closeout.duplicates)?closeout.duplicates:[],
      limitations:[
        'Consent history contains public-application events plus audited in-app changes from the consent-audit implementation onward; older non-application changes may not be reconstructable.',
        'Retention/deletion execution is not yet enterprise-certified.',
        'Private document binary contents are not embedded in this JSON export.'
      ]
    };
    return NextResponse.json(payload,{
      headers:{
        'Cache-Control':'private, no-store',
        'Content-Disposition':`attachment; filename="xzrecruiter-dsar-${candidateId}.json"`
      }
    });
  }catch(error){
    console.error('candidate_dsar_export_failed',error?.status||'',error?.message||'');
    return NextResponse.json({ok:false,error:'dsar_export_unavailable'},{status:503});
  }
}
