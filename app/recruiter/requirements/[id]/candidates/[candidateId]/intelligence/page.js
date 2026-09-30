import { notFound } from 'next/navigation';
import AppShell from '@/app/components/AppShell';
import CandidateIntelligenceWorkspace from '@/app/components/CandidateIntelligenceWorkspace';
import { requireReadyWorkspace } from '@/lib/workspace-ready';
import { getCandidateIntelligenceContext } from '@/lib/candidate-intelligence';
import { candidateAiConfigured } from '@/lib/candidate-ai-server';

export const dynamic='force-dynamic';

export default async function CandidateIntelligencePage({params}){
  const {id:jobId,candidateId}=await params;
  const {user,globalContext}=await requireReadyWorkspace();
  const context=await getCandidateIntelligenceContext(jobId,candidateId).catch(()=>null);
  if(!context?.ok||!context.candidate||!context.job)notFound();

  return <AppShell user={user} globalSettings={globalContext.settings} active="recruiter-work">
    <CandidateIntelligenceWorkspace
      initialContext={context}
      jobId={jobId}
      candidateId={candidateId}
      aiConfigured={candidateAiConfigured()}
    />
  </AppShell>;
}
