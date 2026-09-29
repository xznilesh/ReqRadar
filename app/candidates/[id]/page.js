import CandidateOwnershipPanel from '@/app/components/CandidateOwnershipPanel';
import { notFound } from 'next/navigation';
import AppShell from '@/app/components/AppShell';
import CandidateProfileEditor from '@/app/components/CandidateProfileEditor';
import { requireReadyWorkspace } from '@/lib/workspace-ready';
import { redirectRecruiterFromLegacyWorkspace } from '@/lib/recruiter-access';
import { atsAction } from '@/lib/ats';

export const dynamic='force-dynamic';

export default async function CandidateProfilePage({params}){
  const {id}=await params;
  const {user,globalContext}=await requireReadyWorkspace();
  await redirectRecruiterFromLegacyWorkspace();
  const result=await atsAction('candidateProfileContext',{candidateId:id}).catch(()=>null);
  if(!result?.ok||!result.profile)notFound();
  const ownership=await atsAction('transferCandidateOwner',{candidateId:id}).catch(()=>null);
  const p=result.profile;
  return <AppShell user={user} globalSettings={globalContext.settings} active="candidates">
    <div className="page-heading"><div><span className="page-kicker">Recruitment · Candidate 360</span><h1>{p.fullName}</h1><p>{p.currentTitle||p.headline||'Candidate profile'}{p.currentCompany?` · ${p.currentCompany}`:''}</p></div><a className="ghost-action" href="/candidates">← Candidate list</a></div>
    <CandidateProfileEditor profile={p} countries={globalContext.countries||[]} timezones={globalContext.timezones||[]}/>
    <CandidateOwnershipPanel candidateId={id} initial={ownership}/>
  </AppShell>;
}
