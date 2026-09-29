'use client';

import ClientSubmissionPresentation from '@/app/components/ClientSubmissionPresentation';
import { useMemo,useState } from 'react';

const RETURN_REASONS=[
  ['MISSING_CANDIDATE_INFORMATION','Missing candidate information'],['SCREENING_INCOMPLETE','Screening incomplete'],
  ['CLIENT_REQUIREMENT_MISMATCH','Client requirement mismatch'],['COMPENSATION_ISSUE','Compensation issue'],
  ['AVAILABILITY_ISSUE','Availability issue'],['RESUME_ISSUE','Resume issue'],['SKILL_EVIDENCE_INSUFFICIENT','Skill evidence insufficient'],
  ['WORK_AUTHORIZATION_CONCERN','Work authorization concern'],['PRESENTATION_QUALITY','Presentation quality'],
  ['DUPLICATE_SUBMISSION','Duplicate submission'],['OTHER','Other']
];
const CHECKS=[
  ['approved_requirement_match','Approved requirement match'],['priority_skills','Priority skills / client constraints'],
  ['candidate_interest','Candidate interest confirmed'],['human_screening','Human screening completed'],['key_facts_verified','Key facts verified'],
  ['compensation','Compensation / rate correct'],['location_work_model','Location / work model'],['availability','Availability / notice'],
  ['hard_rule_warnings','Hard-rule warnings reviewed'],['authorization_compliance','Authorization / compliance'],['duplicate_risk','Duplicate submission risk'],
  ['correct_resume','Correct resume'],['concise_summary','Concise candidate summary'],['no_contradictions','No contradictory data'],['client_content_complete','Client-facing content complete']
];
function list(v){return Array.isArray(v)?v:[]}
function pretty(v){return String(v??'UNKNOWN').replaceAll('_',' ').replace(/\b\w/g,x=>x.toUpperCase())}
function value(v){return v&&typeof v==='object'&&'value' in v?v.value:v}
function show(v){const x=value(v);if(x===null||x===undefined||x===''||(Array.isArray(x)&&!x.length))return 'UNKNOWN';if(typeof x==='object')return JSON.stringify(x);return Array.isArray(x)?x.join(', '):String(x)}
function prov(v){return v&&typeof v==='object'&&v.provenance?v.provenance:null}
function when(v){if(!v)return '—';try{return new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(new Date(v))}catch{return String(v)}}
async function api(body){const r=await fetch('/api/submissions',{method:'POST',headers:{'content-type':'application/json','idempotency-key':crypto.randomUUID()},body:JSON.stringify(body)});const d=await r.json().catch(()=>({error:'invalid_response'}));if(!r.ok){const e=new Error(d?.error||'request_failed');e.data=d;throw e}return d}

function Fact({label,fact}){return <div className="s6-fact"><span>{label}</span><b>{show(fact)}</b>{prov(fact)?<small>{pretty(prov(fact))}</small>:null}</div>}
function FindingList({title,items,empty='None recorded'}){const rows=list(items);return <section className="s6-card"><div className="s6-card-head"><h3>{title}</h3><span>{rows.length}</span></div>{rows.length?<div className="s6-findings">{rows.map((x,i)=><article key={i}><b>{x.label||pretty(x.dimension||x.status||'Finding')}</b><p>{x.narrative||x.reason||x.rationale||'Evidence-backed finding'}</p>{list(x.evidence).length?<small>{list(x.evidence).slice(0,3).join(' · ')}</small>:null}</article>)}</div>:<p className="s6-muted">{empty}</p>}</section>}

export default function SubmissionPackWorkspace({initialContext,applicationId,mode='recruiter'}){
  const[ctx,setCtx]=useState(initialContext||{});const[busy,setBusy]=useState('');const[msg,setMsg]=useState('');
  const[recruiterContext,setRecruiterContext]=useState('');const[reason,setReason]=useState('');const[note,setNote]=useState('');
  const[checks,setChecks]=useState(Object.fromEntries(CHECKS.map(([k])=>[k,false])));
  const submission=ctx.submission||{};const current=ctx.currentVersion||{};const pack=current.submissionPack||{};const clientPack=current.clientFacingPack||{};
  const elig=ctx.eligibility||current.eligibility||{};const candidate=ctx.candidate||{};const job=ctx.job||{};const role=ctx.businessRole||'';
  const workflow=submission.workflow_status||'DRAFT';const version=Number(submission.latest_version_number||current.versionNumber||0);const lock=Number(submission.version_lock||0);
  const isAm=mode==='am'||['OWNER','ADMIN','ACCOUNT_MANAGER'].includes(role);const canGenerate=['DRAFT','RETURNED_TO_RECRUITER'].includes(workflow)||!submission.id;
  const unresolved=list(pack.openRisksUncertainties);const gaps=list(pack.knownGaps);const must=list(pack.mustHaveMatch);
  const readiness=useMemo(()=>[
    ['Candidate qualified',elig.candidacyState==='QUALIFIED'],['Screening complete',ctx.screening?.completed===true],['Interest confirmed',ctx.screening?.interestConfirmed===true],
    ['Current intelligence',Boolean(ctx.candidateIntelligence?.id)&&ctx.candidateIntelligence?.run_status==='SUCCEEDED'],['Latest resume',Boolean(ctx.resume?.documentId)],['No server blocker',elig.eligible===true]
  ],[ctx,elig]);

  async function refresh(){const r=await fetch('/api/submissions?applicationId='+encodeURIComponent(applicationId),{cache:'no-store'});const d=await r.json();if(d?.ok)setCtx(d)}
  async function act(action,extra={}){setBusy(action);setMsg('');try{const d=await api({action,applicationId,submissionId:submission.id,expectedVersion:version,expectedLock:lock,...extra});await refresh();setMsg(action==='generate'?(d.reused?'Current source version reused.':'New versioned Submission Pack generated.'):'Action recorded.');}catch(e){setMsg((e.data?.error||e.message)+(e.data?.regenerateRequired?' · Regenerate from current source data.':''));}finally{setBusy('')}}

  return <div className="s6-workspace">
    <section className="s6-hero"><div><span>Step 6 · AI Submission Pack + AM Quality Gate</span><h1>{candidate.fullName||'Candidate'} → {job.title||'Requirement'}</h1><p>Verified screening facts and approved requirement context become one versioned submission. AI-derived content never becomes verified without evidence.</p></div><div className="s6-state"><b>{pretty(workflow)}</b><small>Pack v{version||'—'} · lock {lock}</small></div></section>
    {msg?<div className={/failed|forbidden|stale|not_|required|invalid|blocked|duplicate/i.test(msg)?'s6-message error':'s6-message'}>{pretty(msg)}</div>:null}

    <section className="s6-grid s6-readiness"><article className="s6-card"><div className="s6-card-head"><h2>Submission readiness</h2><span>{elig.eligible?'READY':'BLOCKED'}</span></div>{readiness.map(([k,ok])=><div className="s6-check" key={k}><b>{ok?'✓':'!'}</b><span>{k}</span></div>)}{list(elig.reasons).length?<div className="s6-blockers">{list(elig.reasons).map(x=><span key={x}>{pretty(x)}</span>)}</div>:null}</article>
      <article className="s6-card"><div className="s6-card-head"><h2>Version anchors</h2><span>immutable</span></div><Fact label="Requirement" fact={{value:`v${current.requirementVersion||ctx.requirement?.versionNumber||'?'}`,provenance:'CLIENT_CONFIRMED'}}/><Fact label="Resume" fact={{value:`v${current.resumeVersionNumber||ctx.resume?.versionNumber||'?'}`,provenance:'DOCUMENT_VERIFIED'}}/><Fact label="Screening" fact={{value:current.screeningVersion||ctx.screening?.version||'UNKNOWN',provenance:'RECRUITER_VERIFIED'}}/></article>
    </section>

    <section className="s6-card"><h2>Previous submission history</h2>{list(ctx.previousSubmissions).length?<ul>{ctx.previousSubmissions.map(s=><li key={s.id}>{s.client_name||'Client'} · {s.job_title} · {pretty(s.workflow_status)} · {when(s.client_submitted_at)}</li>)}</ul>:<p>No other submissions visible for this candidate.</p>}</section>
    {canGenerate&&!isAm?<section className="s6-card"><div className="s6-card-head"><div><h2>Recruiter pre-submission review</h2><p>Correct source facts in their proper workflow, then regenerate. Do not rewrite generated facts here.</p></div></div><label className="s6-field"><span>Concise recruiter context (internal only)</span><textarea rows="3" value={recruiterContext} onChange={e=>setRecruiterContext(e.target.value)} maxLength={1200}/></label><button className="primary-action" disabled={busy||elig.eligible!==true} onClick={()=>act('generate',{recruiterContext})}>{busy==='generate'?'Generating…':version?'Regenerate from current facts':'Generate Submission Pack'}</button></section>:null}

    {current.id?<>
      <section className="s6-card"><div className="s6-card-head"><div><span className="page-kicker">Client-ready fast read</span><h2>Submission Pack</h2></div><span>v{current.versionNumber}</span></div>
        <div className="s6-facts"><Fact label="Candidate" fact={pack.candidateSummary?.name||pack.candidateSummary?.facts?.name}/><Fact label="Current role" fact={pack.candidateSummary?.currentTitle||pack.candidateSummary?.facts?.currentTitle}/><Fact label="Interest" fact={pack.candidateInterest}/><Fact label="Availability" fact={pack.availability?.status||pack.availability?.availability}/><Fact label="Notice" fact={pack.availability?.noticePeriodDays}/><Fact label="Work authorization" fact={pack.workAuthorization}/></div>
      </section>
      <div className="s6-grid"><FindingList title="Why candidate fits" items={pack.whyCandidateFits}/><FindingList title="Known gaps" items={gaps}/><FindingList title="Open risks / uncertainties" items={unresolved}/></div>
      <section className="s6-card"><div className="s6-card-head"><h2>Must-have match</h2><span>{must.length}</span></div><div className="s6-must">{must.length?must.slice(0,12).map((x,i)=><article key={i}><b>{x.requirement||x.label||x.dimension||'Requirement'}</b><span>{pretty(x.status||'UNKNOWN')}</span><p>{x.rationale||x.reason||''}</p></article>):<p className="s6-muted">No structured must-have results.</p>}</div></section>
      <section className="s6-card"><div className="s6-card-head"><h2>Client-facing preview</h2><span>sanitized</span></div><ClientSubmissionPresentation pack={clientPack} defaultFormat={ctx.configuration?.raw?.presentationFormat}/></section>
    </>:null}

    {!isAm&&current.id&&['DRAFT','RETURNED_TO_RECRUITER'].includes(workflow)?<section className="s6-card s6-action"><div><h2>Send internally to Account Manager</h2><p>Server revalidates qualification, screening, interest, hard rules, resume and source fingerprint before handoff.</p></div><button className="primary-action" disabled={busy||elig.eligible!==true} onClick={()=>act('sendToAm')}>{busy==='sendToAm'?'Sending…':'Send to AM Quality Gate →'}</button></section>:null}

    {isAm&&workflow==='INTERNAL_SUBMITTED'?<section className="s6-card s6-am"><div className="s6-card-head"><div><span className="page-kicker">Account Manager authority</span><h2>Quality Gate</h2><p>Validate client intent, commercial correctness, risk and presentation. Do not repeat recruiter screening.</p></div></div>
      <div className="s6-checklist">{CHECKS.map(([k,label])=><label key={k}><input type="checkbox" checked={checks[k]} onChange={e=>setChecks(v=>({...v,[k]:e.target.checked}))}/><span>{label}</span></label>)}</div>
      <div className="s6-am-fields"><label className="s6-field"><span>Structured reason</span><select value={reason} onChange={e=>setReason(e.target.value)}><option value="">Select when returning/declining</option>{RETURN_REASONS.map(([k,l])=><option value={k} key={k}>{l}</option>)}</select></label><label className="s6-field"><span>Short note</span><textarea rows="3" value={note} onChange={e=>setNote(e.target.value)} maxLength={1500}/></label></div>
      <div className="s6-actions"><button disabled={busy} onClick={()=>act('amDecision',{decision:'RETURN_TO_RECRUITER',reasonCode:reason,note,checklist:checks})}>Return to recruiter</button><button disabled={busy} onClick={()=>act('amDecision',{decision:'ON_HOLD',note,checklist:checks})}>Hold</button><button disabled={busy} onClick={()=>act('amDecision',{decision:'DECLINE_INTERNAL',reasonCode:reason,note,checklist:checks})}>Decline internal</button><button className="primary-action" disabled={busy} onClick={()=>act('amDecision',{decision:'APPROVE',note,checklist:checks})}>Approve</button></div>
    </section>:null}

    {isAm&&workflow==='AM_APPROVED'?<section className="s6-card s6-action"><div><h2>Final client submission</h2><p>This freezes the exact approved pack, resume version, requirement version and commercial snapshot presented to the client.</p></div><button className="primary-action" disabled={busy} onClick={()=>act('clientSubmit',{clientContact:{}})}>{busy==='clientSubmit'?'Submitting…':'Mark Client Submitted'}</button></section>:null}

    <section className="s6-card"><div className="s6-card-head"><h2>Review & version history</h2><span>{list(ctx.reviewHistory).length} reviews · {list(ctx.versionHistory).length} versions</span></div><div className="s6-history">{list(ctx.reviewHistory).map(r=><article key={r.id}><b>{pretty(r.decision)}</b><span>{r.reason_code?pretty(r.reason_code):''}</span><p>{r.note||''}</p><small>v{r.submission_version_number} · {when(r.created_at)}</small></article>)}</div></section>
  </div>;
}
