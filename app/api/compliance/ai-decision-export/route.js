import { NextResponse } from 'next/server';
import { getCurrentUser } from '@/lib/auth';
import { atsAction } from '@/lib/ats';

export const runtime='nodejs';
export const dynamic='force-dynamic';

const AI_DECISION_EXPORT_VERSION='1.0';

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

  const applicationId=String(req.nextUrl.searchParams.get('applicationId')||'');
  if(!uuid(applicationId))return NextResponse.json({ok:false,error:'invalid_application_id'},{status:400});

  try{
    const [screening,closeout]=await Promise.all([
      atsAction('screeningContext',{applicationId}),
      atsAction('applicationCloseout',{applicationId})
    ]);
    if(!screening?.ok){
      const status=screening?.error==='unauthorized'?401:screening?.error==='forbidden'?403:404;
      return NextResponse.json({ok:false,error:screening?.error||'screening_context_unavailable'},{status});
    }
    if(!closeout?.ok){
      const status=closeout?.error==='unauthorized'?401:closeout?.error==='forbidden'?403:404;
      return NextResponse.json({ok:false,error:closeout?.error||'application_context_unavailable'},{status});
    }

    const generatedAt=new Date().toISOString();
    const payload={
      ok:true,
      export_type:'AI_DECISION_AND_HUMAN_REVIEW',
      export_version:AI_DECISION_EXPORT_VERSION,
      generated_at:generatedAt,
      generated_by:{user_id:user.id,role:user.role},
      subject:{type:'application',application_id:applicationId},
      decision_governance:{
        automated_final_decision:false,
        human_review_required:true,
        purpose:'Recruiting decision transparency and customer compliance evidence.',
        note:'AI-derived analysis is evidence/support only. Human screening, override, AM/client and downstream workflow evidence are exported separately.'
      },
      screening_evidence:screening,
      human_review_export:{
        screening_sessions:screening.sessions||screening.screeningSessions||[],
        screening_summary:screening.summary||screening.screeningSummary||null,
        human_overrides:screening.overrides||screening.humanOverrides||[],
        verified_facts:screening.verifiedFacts||screening.verified_facts||null,
        outcome:screening.outcome||null
      },
      workflow_evidence:{
        application:closeout.application||null,
        submission:closeout.submission||closeout.submissions||null,
        interviews:closeout.interviews||[],
        offers:closeout.offers||[],
        placements:closeout.placements||[],
        activity:closeout.activity||[],
        history:closeout.history||closeout.stage_history||[]
      },
      limitations:[
        'This export reflects evidence available in the current tenant-scoped application record.',
        'External IdP, email/calendar provider and job-board records are not included unless separately integrated and retained.'
      ]
    };

    return NextResponse.json(payload,{
      headers:{
        'Cache-Control':'private, no-store',
        'Content-Disposition':`attachment; filename="xzrecruiter-ai-decision-${applicationId}.json"`
      }
    });
  }catch(error){
    console.error('ai_decision_compliance_export_failed',error?.status||'',error?.message||'');
    return NextResponse.json({ok:false,error:'ai_decision_export_unavailable'},{status:503});
  }
}
