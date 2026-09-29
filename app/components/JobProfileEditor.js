'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';

const STATUS=['DRAFT','PENDING_APPROVAL','OPEN','ON_HOLD','FILLED','CLOSED','CANCELLED'];
const PRIORITY=['LOW','NORMAL','HIGH','URGENT'];
const WORKPLACE=['ONSITE','HYBRID','REMOTE','FLEXIBLE'];
const EMPLOYMENT=['FULL_TIME','PART_TIME','PERMANENT','CONTRACT','TEMPORARY','FREELANCE','INTERNSHIP'];
const PERIOD=['HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL'];
const VISIBILITY=['PRIVATE','INTERNAL','PUBLIC'];
const QUESTION_TYPES=['TEXT','YES_NO','SINGLE_SELECT','MULTI_SELECT','NUMBER','DATE','RATING'];

function listText(value){return Array.isArray(value)?value.map((x)=>typeof x==='string'?x:(x?.label||x?.name||x?.text||JSON.stringify(x))).filter(Boolean).join('\n'):''}
function parseLines(value){return String(value||'').split(/\n|,/).map((x)=>x.trim()).filter(Boolean).filter((x,i,a)=>a.findIndex((y)=>y.toLowerCase()===x.toLowerCase())===i)}
function questionId(){return `q_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,7)}`}
async function ats(action,payload){const res=await fetch('/api/ats',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,payload})});const data=await res.json().catch(()=>({error:'invalid_response'}));if(!res.ok)throw new Error(data?.error||'request_failed');return data}

export default function JobProfileEditor({job,clients=[],pipelines=[],countries=[],timezones=[]}){
 const router=useRouter();
 const[form,setForm]=useState({...job,skillsRequiredText:listText(job.skillsRequired),skillsPreferredText:listText(job.skillsPreferred),mandatoryRequirementsText:listText(job.mandatoryRequirements),preferredRequirementsText:listText(job.preferredRequirements),benefitsText:listText(job.benefits),workAuthorizationText:listText(job.workAuthorizationRequirements),tagsText:listText(job.tags),screeningQuestions:Array.isArray(job.screeningQuestions)?job.screeningQuestions:[]});
 const[state,setState]=useState('idle');const[error,setError]=useState('');
 const zones=useMemo(()=>timezones.filter((z)=>!form.countryCode||z.country_code===form.countryCode),[timezones,form.countryCode]);
 function set(field,value){setForm((f)=>({...f,[field]:value}));if(state!=='saving')setState('dirty')}
 function setQuestion(index,field,value){setForm((f)=>({...f,screeningQuestions:f.screeningQuestions.map((q,i)=>i===index?{...q,[field]:value}:q)}));setState('dirty')}
 function addQuestion(){setForm((f)=>({...f,screeningQuestions:[...f.screeningQuestions,{id:questionId(),question:'',type:'TEXT',required:false,knockout:false,options:[]}]}));setState('dirty')}
 function removeQuestion(index){setForm((f)=>({...f,screeningQuestions:f.screeningQuestions.filter((_,i)=>i!==index)}));setState('dirty')}
 async function save(){setState('saving');setError('');const payload={...form,skillsRequired:parseLines(form.skillsRequiredText),skillsPreferred:parseLines(form.skillsPreferredText),mandatoryRequirements:parseLines(form.mandatoryRequirementsText),preferredRequirements:parseLines(form.preferredRequirementsText),benefits:parseLines(form.benefitsText),workAuthorizationRequirements:parseLines(form.workAuthorizationText),tags:parseLines(form.tagsText),screeningQuestions:form.screeningQuestions.map((q)=>({...q,id:q.id||questionId(),question:String(q.question||'').trim(),type:q.type||'TEXT',required:Boolean(q.required),knockout:Boolean(q.knockout),options:Array.isArray(q.options)?q.options:parseLines(q.optionsText||'')})).filter((q)=>q.question)};try{const data=await ats('updateJobProfile',{jobId:job.id,job:payload});setState('saved');if(data.public_slug&&data.public_slug!==form.publicSlug)setForm((f)=>({...f,publicSlug:data.public_slug}));router.refresh()}catch(e){setState('error');setError(e.message||'Could not save job profile.')}}
 return <div className="candidate-profile-editor job-profile-editor">
  <div className="profile-editor-head"><div><span className="page-kicker">Job 360</span><h2>Requisition & hiring brief</h2><p>Complete job configuration loads on demand so the main requisition list stays fast.</p></div><div className={`profile-save-state ${state}`} aria-live="polite">{state==='saving'?'Saving…':state==='saved'?'Saved':state==='dirty'?'Unsaved changes':state==='error'?'Save failed':'Up to date'}</div></div>
  {error?<div className="save-error profile-error" role="alert">{error}</div>:null}
  <section className="profile-section"><h3>Requisition</h3><div className="form-grid two">
   <label className="form-control wide"><span>Job title *</span><input value={form.title||''} onChange={(e)=>set('title',e.target.value)}/></label>
   <label className="form-control"><span>Internal reference</span><input value={form.internalRef||''} onChange={(e)=>set('internalRef',e.target.value)}/></label>
   <label className="form-control"><span>Client</span><select value={form.clientId||''} onChange={(e)=>set('clientId',e.target.value)}><option value="">Internal / unassigned</option>{clients.map((c)=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
   <label className="form-control"><span>Hiring manager</span><input value={form.hiringManagerName||''} onChange={(e)=>set('hiringManagerName',e.target.value)}/></label>
   <label className="form-control"><span>Hiring manager email</span><input type="email" value={form.hiringManagerEmail||''} onChange={(e)=>set('hiringManagerEmail',e.target.value)}/></label>
   <label className="form-control"><span>Department</span><input value={form.department||''} onChange={(e)=>set('department',e.target.value)}/></label>
   <label className="form-control"><span>Job function</span><input value={form.jobFunction||''} onChange={(e)=>set('jobFunction',e.target.value)}/></label>
   <label className="form-control"><span>Industry</span><input value={form.industry||''} onChange={(e)=>set('industry',e.target.value)}/></label>
   <label className="form-control"><span>Seniority</span><input value={form.seniority||''} onChange={(e)=>set('seniority',e.target.value)}/></label>
   <label className="form-control"><span>Status</span><select value={form.status||'OPEN'} onChange={(e)=>set('status',e.target.value)}>{STATUS.map((v)=><option key={v} value={v}>{v.replaceAll('_',' ')}</option>)}</select></label>
   <label className="form-control"><span>Priority</span><select value={form.priority||'NORMAL'} onChange={(e)=>set('priority',e.target.value)}>{PRIORITY.map((v)=><option key={v} value={v}>{v}</option>)}</select></label>
   <label className="form-control"><span>Recruitment pipeline</span><select value={form.pipelineId||''} onChange={(e)=>set('pipelineId',e.target.value)}><option value="">Default</option>{pipelines.map((p)=><option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
   <label className="form-control"><span>SLA hours</span><input type="number" min="1" value={form.slaHours??''} onChange={(e)=>set('slaHours',e.target.value)}/></label>
   <label className="form-control"><span>Target fill date</span><input type="date" value={form.targetFillDate||''} onChange={(e)=>set('targetFillDate',e.target.value)}/></label>
  </div></section>
  <section className="profile-section"><h3>Location & employment</h3><div className="form-grid two">
   <label className="form-control"><span>Country</span><select value={form.countryCode||''} onChange={(e)=>{setForm((f)=>({...f,countryCode:e.target.value,timezone:''}));setState('dirty')}}><option value="">Select</option>{countries.map((c)=><option key={c.country_code} value={c.country_code}>{c.country_name}</option>)}</select></label>
   <label className="form-control"><span>IANA timezone</span><select value={form.timezone||''} onChange={(e)=>set('timezone',e.target.value)}><option value="">Select</option>{zones.map((z)=><option key={z.timezone_id} value={z.timezone_id}>{z.display_name} · {z.timezone_id}</option>)}</select></label>
   <label className="form-control"><span>Location label</span><input value={form.location||''} onChange={(e)=>set('location',e.target.value)}/></label>
   <label className="form-control"><span>City</span><input value={form.city||''} onChange={(e)=>set('city',e.target.value)}/></label>
   <label className="form-control"><span>Region / state</span><input value={form.region||''} onChange={(e)=>set('region',e.target.value)}/></label>
   <label className="form-control"><span>Workplace</span><select value={form.workplaceType||'ONSITE'} onChange={(e)=>set('workplaceType',e.target.value)}>{WORKPLACE.map((v)=><option key={v} value={v}>{v}</option>)}</select></label>
   <label className="consent-line"><input type="checkbox" checked={Boolean(form.remoteAllowed)} onChange={(e)=>set('remoteAllowed',e.target.checked)}/><span>Remote work explicitly allowed</span></label>
   <label className="form-control"><span>Employment type</span><select value={form.employmentType||'FULL_TIME'} onChange={(e)=>set('employmentType',e.target.value)}>{EMPLOYMENT.map((v)=><option key={v} value={v}>{v.replaceAll('_',' ')}</option>)}</select></label>
   <label className="form-control"><span>Contract duration</span><input value={form.contractDuration||''} onChange={(e)=>set('contractDuration',e.target.value)} placeholder="6 months, ongoing…"/></label>
   <label className="form-control"><span>Experience min (years)</span><input type="number" min="0" step="0.5" value={form.experienceMin??''} onChange={(e)=>set('experienceMin',e.target.value)}/></label>
   <label className="form-control"><span>Experience max (years)</span><input type="number" min="0" step="0.5" value={form.experienceMax??''} onChange={(e)=>set('experienceMax',e.target.value)}/></label>
   <label className="form-control"><span>Openings</span><input type="number" min="1" value={form.openings??1} onChange={(e)=>set('openings',e.target.value)}/></label>
  </div></section>
  <section className="profile-section"><h3>Compensation & authorization</h3><div className="form-grid two">
   <label className="form-control"><span>Salary min</span><input type="number" min="0" value={form.salaryMin??''} onChange={(e)=>set('salaryMin',e.target.value)}/></label>
   <label className="form-control"><span>Salary max</span><input type="number" min="0" value={form.salaryMax??''} onChange={(e)=>set('salaryMax',e.target.value)}/></label>
   <label className="form-control"><span>Currency</span><input maxLength="3" value={form.salaryCurrency||''} onChange={(e)=>set('salaryCurrency',e.target.value.toUpperCase())}/></label>
   <label className="form-control"><span>Period</span><select value={form.salaryPeriod||'ANNUAL'} onChange={(e)=>set('salaryPeriod',e.target.value)}>{PERIOD.map((v)=><option key={v} value={v}>{v}</option>)}</select></label>
   <label className="form-control"><span>OTE</span><input type="number" min="0" value={form.salaryOte??''} onChange={(e)=>set('salaryOte',e.target.value)}/></label>
   <label className="form-control"><span>Bonus</span><input type="number" min="0" value={form.bonus??''} onChange={(e)=>set('bonus',e.target.value)}/></label>
   <label className="form-control"><span>Commission</span><input type="number" min="0" value={form.commission??''} onChange={(e)=>set('commission',e.target.value)}/></label>
   <label className="consent-line"><input type="checkbox" checked={Boolean(form.sponsorshipAvailable)} onChange={(e)=>set('sponsorshipAvailable',e.target.checked)}/><span>Employer sponsorship available</span></label>
   <label className="form-control wide"><span>Work authorization requirements</span><textarea rows="3" value={form.workAuthorizationText||''} onChange={(e)=>set('workAuthorizationText',e.target.value)} placeholder="UK unrestricted\nEU work authorization\nSponsorship considered"/></label>
  </div></section>
  <section className="profile-section"><h3>Role brief</h3><div className="form-grid two">
   <label className="form-control wide"><span>Description</span><textarea rows="8" value={form.description||''} onChange={(e)=>set('description',e.target.value)}/></label>
   <label className="form-control"><span>Required skills</span><textarea rows="5" value={form.skillsRequiredText||''} onChange={(e)=>set('skillsRequiredText',e.target.value)} placeholder="One per line"/></label>
   <label className="form-control"><span>Preferred skills</span><textarea rows="5" value={form.skillsPreferredText||''} onChange={(e)=>set('skillsPreferredText',e.target.value)} placeholder="One per line"/></label>
   <label className="form-control"><span>Mandatory requirements</span><textarea rows="5" value={form.mandatoryRequirementsText||''} onChange={(e)=>set('mandatoryRequirementsText',e.target.value)}/></label>
   <label className="form-control"><span>Preferred requirements</span><textarea rows="5" value={form.preferredRequirementsText||''} onChange={(e)=>set('preferredRequirementsText',e.target.value)}/></label>
   <label className="form-control wide"><span>Benefits</span><textarea rows="4" value={form.benefitsText||''} onChange={(e)=>set('benefitsText',e.target.value)} placeholder="One benefit per line"/></label>
  </div></section>
  <section className="profile-section"><div className="closeout-title"><div><h3>Pre-screening questions</h3><small>Questions appear on the public application. Knockout flags are evidence only; they do not auto-reject.</small></div><button className="ghost-action" type="button" onClick={addQuestion}>＋ Question</button></div>
   {form.screeningQuestions.length?<div className="job-question-list">{form.screeningQuestions.map((q,i)=><article className="job-question" key={q.id||i}><div className="form-grid two"><label className="form-control wide"><span>Question</span><input value={q.question||''} onChange={(e)=>setQuestion(i,'question',e.target.value)} placeholder="Are you authorised to work in the UK?"/></label><label className="form-control"><span>Answer type</span><select value={q.type||'TEXT'} onChange={(e)=>setQuestion(i,'type',e.target.value)}>{QUESTION_TYPES.map((v)=><option key={v} value={v}>{v.replaceAll('_',' ')}</option>)}</select></label><label className="form-control"><span>Options</span><input disabled={!['SINGLE_SELECT','MULTI_SELECT'].includes(q.type)} value={Array.isArray(q.options)?q.options.join(', '):(q.optionsText||'')} onChange={(e)=>setQuestion(i,'options',parseLines(e.target.value))} placeholder="Yes, No, Maybe"/></label></div><div className="question-flags"><label><input type="checkbox" checked={Boolean(q.required)} onChange={(e)=>setQuestion(i,'required',e.target.checked)}/> Required</label><label><input type="checkbox" checked={Boolean(q.knockout)} onChange={(e)=>setQuestion(i,'knockout',e.target.checked)}/> Knockout evidence</label><button type="button" className="danger-action" onClick={()=>removeQuestion(i)}>Remove</button></div></article>)}</div>:<div className="ats-empty"><span>No pre-screening questions configured.</span><button onClick={addQuestion}>Add first question</button></div>}
  </section>
  <section className="profile-section"><h3>Publishing & tags</h3><div className="form-grid two"><label className="form-control"><span>Visibility</span><select value={form.publicVisibility||'PRIVATE'} onChange={(e)=>set('publicVisibility',e.target.value)}>{VISIBILITY.map((v)=><option key={v}>{v}</option>)}</select></label><label className="form-control wide"><span>Tags</span><textarea rows="3" value={form.tagsText||''} onChange={(e)=>set('tagsText',e.target.value)} placeholder="Priority client\nConfidential"/></label></div>{form.publicVisibility==='PUBLIC'&&form.publicSlug?<a className="ghost-action public-job-link" href={`/jobs/public/${form.publicSlug}`} target="_blank" rel="noreferrer">Open public job ↗</a>:null}</section>
  <div className="profile-sticky-actions"><a className="ghost-action" href="/jobs">← Jobs</a><button className="primary-action" disabled={state==='saving'||!form.title||!form.clientId} onClick={save}>{state==='saving'?'Saving…':'Save Job 360'}</button></div>
 </div>
}
