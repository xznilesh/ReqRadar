import RequirementCommercialPanel from '@/app/components/RequirementCommercialPanel';
import CommunicationTimeline from '@/app/components/CommunicationTimeline';
import { notFound } from 'next/navigation';
import AppShell from '@/app/components/AppShell';
import JobProfileEditor from '@/app/components/JobProfileEditor';
import { requireReadyWorkspace } from '@/lib/workspace-ready';
import { redirectRecruiterFromLegacyWorkspace } from '@/lib/recruiter-access';
import { atsAction } from '@/lib/ats';

export const dynamic='force-dynamic';

export default async function JobProfilePage({params}){
  const {id}=await params;
  const {user,globalContext}=await requireReadyWorkspace();
  await redirectRecruiterFromLegacyWorkspace();
  const result=await atsAction('jobProfileContext',{jobId:id}).catch(()=>null);
  if(!result?.ok||!result.job)notFound();
  const commercial=await atsAction('requirementCommercial',{jobId:id}).catch(()=>null);
  const j=result.job;
  return <AppShell user={user} globalSettings={globalContext.settings} active="jobs">
    <div className="page-heading"><div><span className="page-kicker">Recruitment · Job 360</span><h1>{j.title}</h1><p>{[j.department,j.city,j.countryCode].filter(Boolean).join(' · ')||'Global requisition'}</p></div><div className="ats-toolbar-actions"><a className="ghost-action" href={`/jobs/${id}/requirement`}>AI JD Brain →</a><a className="ghost-action" href={"/recruiter/requirements/"+id}>Recruiter execution →</a><a className="ghost-action" href="/jobs">← Job list</a></div></div>
    <JobProfileEditor job={j} clients={result.clients||[]} pipelines={result.pipelines||[]} countries={globalContext.countries||[]} timezones={globalContext.timezones||[]}/>
    <RequirementCommercialPanel jobId={id} initial={commercial}/>
    <CommunicationTimeline jobId={id}/>
  </AppShell>;
}
