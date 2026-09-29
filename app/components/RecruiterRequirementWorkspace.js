'use client';

import CommunicationTimeline from '@/app/components/CommunicationTimeline';
import { useMemo,useRef,useState } from 'react';
import { useRouter } from 'next/navigation';

const SOURCES=['LINKEDIN','MONSTER','DICE','INDEED','NAUKRI','INTERNAL_DATABASE','REFERRAL','APPLICANT','CSV','OTHER'];
const TASK_TYPES=['CONTACT_CANDIDATE','FOLLOW_UP','COLLECT_RESUME','CONFIRM_AVAILABILITY','SCREENING_DUE','MISSING_INFORMATION','MANAGER_CLARIFICATION'];
const QUEUES=['ALL','NEW_WORK','SOURCING','FOLLOW_UP_DUE','SCREENING_PENDING','READY_FOR_NEXT_ACTION','BLOCKED','COMPLETED_NO_ACTION'];

function uid(){try{return crypto.randomUUID()}catch{return String(Date.now())+'-'+Math.random().toString(36).slice(2)}}
function list(value){return Array.isArray(value)?value:[]}
function money(job){if(job?.salary_min==null&&job?.salary_max==null)return 'Not provided';const a=job.salary_min!=null?Number(job.salary_min).toLocaleString():'—';const b=job.salary_max!=null?Number(job.salary_max).toLocaleString():'—';return [job.salary_currency,a+(job.salary_max!=null?' – '+b:'') ,job.salary_period].filter(Boolean).join(' ')}
function fmtDue(value,timezone){if(!value)return 'No due time';try{return new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short',timeZone:timezone||'UTC'}).format(new Date(value))}catch{return String(value)}}
function provenanceLabel(item){return item?.provenance==='JD_EVIDENCE'?'Client/JD evidence':'AI sourcing suggestion'}

async function post(body){
 const res=await fetch('/api/recruiter',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
 const data=await res.json().catch(()=>({error:'invalid_response'}));
 if(!res.ok){const e=new Error(data?.error||'request_failed');e.data=data;throw e}
 return data;
}

export default function RecruiterRequirementWorkspace({initialContext,jobId}){
 const router=useRouter();const fileRef=useRef(null);
 const[ctx,setCtx]=useState(initialContext||{});
 const[state,setState]=useState('idle');const[message,setMessage]=useState('');
 const[queueFilter,setQueueFilter]=useState('ALL');
 const[intakeOpen,setIntakeOpen]=useState(false);
 const[intake,setIntake]=useState({candidateId:'',fullName:'',email:'',phone:'',currentTitle:'',currentCompany:'',sourceType:'',sourceReference:'',sourcingNotes:''});
 const[resume,setResume]=useState(null);
 const[search,setSearch]=useState('');const[searchRows,setSearchRows]=useState([]);const[searching,setSearching]=useState(false);
 const[talentQuery,setTalentQuery]=useState('');const[talentRows,setTalentRows]=useState(initialContext?.rediscovery?.rows||[]);const[talentSearching,setTalentSearching]=useState(false);
 const intakeKeyRef=useRef(uid());const taskKeyRef=useRef(uid());const assignmentKeyRef=useRef(uid());
 const[task,setTask]=useState({taskType:'FOLLOW_UP',title:'Follow up with candidate',dueLocal:'',priority:'NORMAL',candidateId:'',applicationId:'',description:''});
 const[assignment,setAssignment]=useState({recruiterUserId:'',dailyTarget:'1',totalTarget:'0',status:'ACTIVE',priority:'',priorityContext:'',managerInstructions:'',blockerType:'',blockerReason:'',blockerOwnerUserId:''});
 const[requirementTargets,setRequirementTargets]=useState({daily:String(initialContext?.job?.submission_target_daily||0),total:String(initialContext?.job?.submission_target_total||0)});

 const job=ctx.job||{};const briefMeta=ctx.brief||{};const brief=briefMeta.hiring_brief||{};const blueprint=briefMeta.search_blueprint||{};
 const criteria=list(ctx.criteria);const execution=ctx.execution||{};const tasks=list(ctx.tasks);const queue=list(ctx.queue);const blockers=list(ctx.blockers);
 const hard=criteria.filter(x=>x.kind==='HARD_REQUIREMENT'&&x.amConfirmed);
 const must=criteria.filter(x=>x.kind==='MUST_HAVE');
 const nice=criteria.filter(x=>x.kind==='NICE_TO_HAVE');
 const canManage=Boolean(ctx.can_manage_assignments);
 const filteredQueue=useMemo(()=>queue.filter(x=>{
   if(queueFilter==='ALL')return true;
   if(queueFilter==='BLOCKED')return Boolean(x.blocked);
   if(queueFilter==='FOLLOW_UP_DUE')return tasks.some(t=>t.application_id===x.application_id&&t.due_today);
   return x.queue_group===queueFilter;
 }),[queue,queueFilter,tasks]);

 async function refresh(){
   const res=await fetch('/api/recruiter?mode=requirement&jobId='+encodeURIComponent(jobId),{cache:'no-store'});
   const data=await res.json().catch(()=>null);
   if(data?.ok){setCtx(data);setRequirementTargets({daily:String(data.job?.submission_target_daily||0),total:String(data.job?.submission_target_total||0)})}
 }

 async function searchExisting(){
   if(search.trim().length<2){setSearchRows([]);return}
   setSearching(true);
   try{
     const res=await fetch('/api/recruiter?mode=candidateSearch&jobId='+encodeURIComponent(jobId)+'&q='+encodeURIComponent(search.trim()),{cache:'no-store'});
     const data=await res.json();
     setSearchRows(data?.rows||[]);
   }catch{setSearchRows([])}finally{setSearching(false)}
 }

 async function searchTalent(){
   setTalentSearching(true);setMessage('');
   try{
     const res=await fetch('/api/candidate-intelligence?mode=talentSearch&jobId='+encodeURIComponent(jobId)+'&q='+encodeURIComponent(talentQuery.trim()),{cache:'no-store'});
     const data=await res.json().catch(()=>({}));
     if(!res.ok)throw new Error(data?.error||'talent_search_failed');
     setTalentRows(data?.rows||[]);
   }catch(e){setState('error');setMessage(e.message);setTalentRows([])}
   finally{setTalentSearching(false)}
 }

 async function addTalentCandidate(row){
   setState('saving');setMessage('');
   try{
     await post({action:'intakeCandidate',jobId,candidate:{id:row.id},sourceType:'INTERNAL_DATABASE',sourceReference:'',sourcingNotes:'Reused from same-tenant talent intelligence search',idempotencyKey:uid()});
     await refresh();await searchTalent();setState('saved');setMessage('Existing talent candidate associated with this requirement.');
   }catch(e){setState('error');setMessage(e.message)}
 }

 function chooseExisting(row){
   setIntake({candidateId:row.id,fullName:row.full_name||'',email:row.email||'',phone:row.phone||'',currentTitle:row.current_title||'',currentCompany:row.current_company||'',sourceType:'INTERNAL_DATABASE',sourceReference:'',sourcingNotes:''});
   setSearchRows([]);setSearch('');
 }

 async function uploadResume(candidateId){
   if(!resume)return;
   const form=new FormData();form.set('jobId',jobId);form.set('candidateId',candidateId);form.set('file',resume);
   const res=await fetch('/api/recruiter/resume',{method:'POST',body:form});
   const data=await res.json().catch(()=>({}));
   if(!res.ok)throw new Error(data?.error||'resume_upload_failed');
 }

 async function intakeCandidate(){
   setState('saving');setMessage('');
   try{
     const data=await post({action:'intakeCandidate',jobId,candidate:intake.candidateId?{id:intake.candidateId}:{fullName:intake.fullName,email:intake.email,phone:intake.phone,currentTitle:intake.currentTitle,currentCompany:intake.currentCompany},sourceType:intake.sourceType,sourceReference:intake.sourceReference,sourcingNotes:intake.sourcingNotes,idempotencyKey:intakeKeyRef.current});
     if(resume)await uploadResume(data.candidate_id);
     setIntakeOpen(false);setResume(null);intakeKeyRef.current=uid();if(fileRef.current)fileRef.current.value='';
     setIntake({candidateId:'',fullName:'',email:'',phone:'',currentTitle:'',currentCompany:'',sourceType:'',sourceReference:'',sourcingNotes:''});
     await refresh();setState('saved');setMessage(data.already_associated?'Candidate was already on this requirement; existing candidacy reused.':data.reused?'Existing candidate reused and associated with this requirement.':'Candidate sourced and added to the requirement.');
   }catch(e){setState('error');setMessage(e.message==='existing_candidate_found'?'An existing candidate with this contact already exists. Search internal talent and reuse that record instead of creating a duplicate.':e.message==='candidate_intake_conflict'?'Candidate intake was retried concurrently. Refresh/search internal talent before retrying.':e.message)}
 }

 function taskFor(row,type='FOLLOW_UP'){
   setTask({taskType:type,title:type==='COLLECT_RESUME'?'Collect resume':type==='SCREENING_DUE'?'Complete candidate screening':'Follow up with candidate',dueLocal:'',priority:'NORMAL',candidateId:row.candidate_id||'',applicationId:row.application_id||'',description:''});
   document.getElementById('rx-task-panel')?.scrollIntoView({behavior:'smooth',block:'center'});
 }

 async function createTask(){
   setState('saving');setMessage('');
   try{
     await post({action:'saveTask',task:{...task,jobId,idempotencyKey:taskKeyRef.current}});taskKeyRef.current=uid();
     await refresh();setState('saved');setMessage('Execution task created.');
   }catch(e){setState('error');setMessage(e.message)}
 }

 async function completeTask(id){
   setState('saving');
   try{await post({action:'setTaskStatus',taskId:id,status:'DONE'});await refresh();setState('saved');setMessage('Task completed.')}
   catch(e){setState('error');setMessage(e.message)}
 }

 async function saveAssignment(){
   setState('saving');setMessage('');
   try{
     await post({action:'saveAssignment',jobId,...assignment,idempotencyKey:assignmentKeyRef.current});assignmentKeyRef.current=uid();
     await refresh();setState('saved');setMessage('Recruiter assignment saved.');
   }catch(e){setState('error');setMessage(e.message)}
 }

 async function saveRequirementTarget(){
   setState('saving');setMessage('');
   try{
     await post({action:'setRequirementTarget',jobId,dailyTarget:Number(requirementTargets.daily||0),totalTarget:Number(requirementTargets.total||0)});
     await refresh();setState('saved');setMessage('Requirement targets updated.');
   }catch(e){setState('error');setMessage(e.message)}
 }

 function BlueprintGroup({title,items}){
   const values=list(items);
   if(!values.length)return null;
   return <div className="rx-blueprint-group"><b>{title}</b><div>{values.map((x,i)=><span key={i} className={x.provenance==='JD_EVIDENCE'?'confirmed':'suggested'} title={list(x.basisEvidence).join(' · ')}>{x.value}<small>{provenanceLabel(x)}</small></span>)}</div></div>;
 }

 return <div className="rx-requirement">
   {message?<div className={state==='error'?'save-error':'pipeline-feedback success'} role="status">{message}</div>:null}

   <section className="rx-execution-strip">
     <div><span>Assigned target</span><b>{execution.daily_target||0}</b></div>
     <div><span>Valid today</span><b>{execution.valid_submissions_today||0}</b></div>
     <div className={Number(execution.remaining_target||0)>0?'attention':'done'}><span>Remaining</span><b>{execution.remaining_target||0}</b></div>
     <div><span>Total target gap</span><b>{execution.remaining_total_target||0}</b></div>
     <div><span>Due date</span><b>{job.target_fill_date||'Not set'}</b></div>
     <div><span>Status</span><b>{job.status||'OPEN'}</b></div>
     <div><span>Blockers</span><b>{blockers.length}</b></div>
     <button className="primary-action" onClick={()=>setIntakeOpen(true)}>＋ Source candidate</button>
   </section>

   <div className="rx-main-grid">
     <section className="rx-section rx-brief-panel">
       <div className="rx-section-head"><div><span className="page-kicker">Approved Step-2 brief</span><h2>Recruiter Brief</h2><p>Read-only client intent. Recruiters execute against it; they do not rewrite it.</p></div><span className="status good">Approved v{briefMeta.version_number||'—'}</span></div>
       <div className="rx-brief-copy"><h3>Role summary</h3><p>{brief.roleSummary||'No role summary supplied.'}</p><h3>Ideal candidate</h3><p>{brief.idealCandidateProfile||'Not explicitly described.'}</p></div>
       <div className="rx-criteria-columns">
         <div><span className="rx-label confirmed">CLIENT-CONFIRMED REQUIREMENT</span><h3>Must-have</h3>{(list(brief.mustHaveCriteria).length?list(brief.mustHaveCriteria):must.map(x=>x.value)).map((x,i)=><p key={i}>✓ {x}</p>)}</div>
         <div><span className="rx-label confirmed">CLIENT-CONFIRMED / APPROVED</span><h3>Confirmed knockout rules</h3>{hard.length?hard.map((x,i)=><p key={i}>⛔ {x.value}</p>):<p>No confirmed knockout rules.</p>}</div>
         <div><span className="rx-label neutral">PREFERENCE</span><h3>Nice-to-have</h3>{(list(brief.niceToHaveCriteria).length?list(brief.niceToHaveCriteria):nice.map(x=>x.value)).map((x,i)=><p key={i}>＋ {x}</p>)}</div>
       </div>
       <div className="rx-facts"><div><span>Location / work model</span><b>{brief.locationWorkModel||[job.city,job.country_code,job.workplace_type].filter(Boolean).join(' · ')||'Not provided'}</b></div><div><span>Experience</span><b>{brief.experienceExpectations||([job.experience_min,job.experience_max].filter(x=>x!=null).join('–')||'Not provided')}</b></div><div><span>Compensation / rate</span><b>{brief.compensationConstraints||money(job)}</b></div><div><span>Authorization</span><b>{brief.workAuthorizationConstraints||list(job.work_authorization_requirements).join(', ')||'Not provided'}</b></div></div>
       {briefMeta.approval_note?<div className="rx-manager-note"><b>AM approval context</b><span>{briefMeta.approval_note}</span></div>:null}
     </section>

     <section className="rx-section rx-blueprint">
       <div className="rx-section-head"><div><span className="page-kicker">Sourcing blueprint</span><h2>Who to search for</h2><p>AI suggestions are visibly separated from client/JD evidence.</p></div></div>
       <BlueprintGroup title="Primary titles" items={blueprint.primaryCandidateTitles}/>
       <BlueprintGroup title="Alternate titles" items={blueprint.alternateTitles}/>
       <BlueprintGroup title="Must-have keywords" items={blueprint.mustHaveKeywords}/>
       <BlueprintGroup title="Skill synonyms" items={blueprint.skillSynonyms}/>
       <BlueprintGroup title="Domain keywords" items={blueprint.domainKeywords}/>
       <BlueprintGroup title="Talent pools" items={blueprint.talentPoolCategories}/>
       {blueprint.booleanSearchDraft?<div className="rx-boolean"><b>Suggested Boolean draft</b><code>{blueprint.booleanSearchDraft}</code><small>AI sourcing suggestion—not a client requirement.</small></div>:null}
     </section>
   </div>

   {blockers.length?<section className="rx-section rx-blockers"><div className="rx-section-head"><div><h2>Execution blockers</h2><p>Only persisted/explicit blockers are shown—no fabricated AI blocker inference.</p></div></div><div className="rx-blocker-list">{blockers.map((b,i)=><article key={i}><b>{b.blocker_type}</b><span>{b.reason}</span><small>Next action owner: {b.owner}</small></article>)}</div></section>:null}

   <section className="rx-section">
     <div className="rx-section-head"><div><span className="page-kicker">Work queue</span><h2>Candidates requiring recruiter action</h2><p>Same candidacy state powers the queue; there is no parallel recruiter pipeline.</p></div><div className="rx-queue-tabs">{QUEUES.map(q=><button key={q} className={queueFilter===q?'active':''} onClick={()=>setQueueFilter(q)}>{q.replaceAll('_',' ')}</button>)}</div></div>
     <div className="rx-work-list">{filteredQueue.length?filteredQueue.map(row=><article key={row.application_id} className={row.blocked?'blocked':''}>
       <div><b>{row.full_name}</b><span>{[row.current_title,row.current_company].filter(Boolean).join(' · ')||'Candidate'}</span><small>{row.source_type||'UNKNOWN SOURCE'}{row.sourced_at?' · sourced '+fmtDue(row.sourced_at,ctx.timezone):''}</small></div>
       <div className="rx-work-state"><span>{String(row.queue_group||'SOURCING').replaceAll('_',' ')}</span><small>{String(row.canonical_state||row.stage_code||row.stage||'SOURCED').replaceAll('_',' ')}</small></div>
       <div className="rx-row-actions"><a href={'/recruiter/requirements/'+jobId+'/candidates/'+row.candidate_id+'/intelligence'}>Intelligence</a><button onClick={()=>taskFor(row,'FOLLOW_UP')}>Follow-up</button><button onClick={()=>taskFor(row,'COLLECT_RESUME')}>Resume</button><button onClick={()=>taskFor(row,'SCREENING_DUE')}>Screening</button></div>
     </article>):<div className="rx-empty compact">No candidates in this queue. Source/add a candidate to begin execution.</div>}</div>
   </section>

   <section className="rx-section">
     <div className="rx-section-head"><div><span className="page-kicker">Step 4 · Talent intelligence</span><h2>Candidate rediscovery</h2><p>Tenant scope first → approved must-have skill coverage → lexical relevance. Suggestions load automatically for this approved requirement.</p></div></div>
     <div className="rx-internal-search"><input value={talentQuery} onChange={e=>setTalentQuery(e.target.value)} placeholder="Optional: title, skill, company or location"/><button onClick={searchTalent} disabled={talentSearching}>{talentSearching?'Ranking…':'Find matching talent'}</button></div>
     <div className="rx-search-results">{talentRows.length?talentRows.map(row=><article key={row.id}><div><b>{row.full_name}</b><span>{[row.current_title,row.current_company,row.city,row.country_code].filter(Boolean).join(' · ')}</span><small>{row.required_skill_count?String(row.matched_skill_count)+'/'+String(row.required_skill_count)+' approved must-have skills evidenced':'No structured skill baseline'}{row.intelligence_available?' · normalized profile available':' · legacy profile evidence'}</small>{row.previous_strong_match?<small>Previous strong match · {row.previous_strong_match.score}% · {row.previous_strong_match.requiresReassessment?'reassess for this requirement':'current requirement evidence'}</small>:null}</div>{row.already_on_requirement?<a href={'/recruiter/requirements/'+jobId+'/candidates/'+row.id+'/intelligence'}>Open intelligence</a>:<button onClick={()=>addTalentCandidate(row)}>Add to requirement</button>}</article>):<div className="rx-empty compact">No suggestions loaded. Use Find matching talent to retry or broaden the search.</div>}</div>
   </section>

   <div className="rx-two-col">
     <section className="rx-section" id="rx-task-panel"><div className="rx-section-head"><div><h2>Create follow-up / task</h2><p>Recruitment execution only—not a project-management layer.</p></div></div>
       <div className="form-grid two"><label className="form-control"><span>Type</span><select value={task.taskType} onChange={e=>setTask({...task,taskType:e.target.value})}>{TASK_TYPES.map(x=><option key={x}>{x.replaceAll('_',' ')}</option>)}</select></label><label className="form-control"><span>Priority</span><select value={task.priority} onChange={e=>setTask({...task,priority:e.target.value})}>{['LOW','NORMAL','HIGH','URGENT'].map(x=><option key={x}>{x}</option>)}</select></label><label className="form-control wide"><span>Task</span><input value={task.title} onChange={e=>setTask({...task,title:e.target.value})}/></label><label className="form-control"><span>Due date/time · {ctx.timezone}</span><input type="datetime-local" value={task.dueLocal} onChange={e=>setTask({...task,dueLocal:e.target.value})}/></label><label className="form-control wide"><span>Context</span><textarea rows="3" value={task.description} onChange={e=>setTask({...task,description:e.target.value})}/></label></div>
       <button className="primary-action" onClick={createTask} disabled={!task.title||state==='saving'}>Create task</button>
       <div className="rx-list rx-task-list">{tasks.map(t=><article key={t.id} className={t.overdue?'overdue':''}><div><b>{t.title}</b><span>{t.candidate_name||String(t.task_type||'').replaceAll('_',' ')}</span><small>{fmtDue(t.due_at,ctx.timezone)}</small></div><button onClick={()=>completeTask(t.id)}>Done</button></article>)}</div>
     </section>

     <section className="rx-section"><div className="rx-section-head"><div><h2>Execution snapshot</h2><p>System-tracked progress; no manual activity logging required.</p></div></div>
       <div className="rx-snapshot"><div><span>Pipeline candidates</span><b>{queue.length}</b></div><div><span>Open tasks</span><b>{tasks.filter(t=>['OPEN','IN_PROGRESS'].includes(t.status)).length}</b></div><div><span>Overdue</span><b>{tasks.filter(t=>t.overdue).length}</b></div><div><span>Valid submissions today</span><b>{execution.valid_submissions_today||0}</b></div></div>
     </section>
   </div>

   {canManage?<section className="rx-section rx-manager-controls"><div className="rx-section-head"><div><span className="page-kicker">Manager controls</span><h2>Recruiter assignment & targets</h2><p>Operational assignment only; approved Hiring Brief remains protected.</p></div></div>
     <div className="rx-assignment-grid">
       <div><h3>Requirement targets</h3><div className="rx-inline"><input aria-label="Requirement daily target" type="number" min="0" max="1000" value={requirementTargets.daily} onChange={e=>setRequirementTargets({...requirementTargets,daily:e.target.value})} placeholder="Daily"/><input aria-label="Requirement total target" type="number" min="0" max="10000" value={requirementTargets.total} onChange={e=>setRequirementTargets({...requirementTargets,total:e.target.value})} placeholder="Total"/><button onClick={saveRequirementTarget}>Save targets</button></div></div>
       <div><h3>Assign recruiter</h3><div className="form-grid two"><label className="form-control"><span>Recruiter</span><select value={assignment.recruiterUserId} onChange={e=>setAssignment({...assignment,recruiterUserId:e.target.value})}><option value="">Choose recruiter</option>{list(ctx.eligible_recruiters).map(r=><option key={r.user_id} value={r.user_id}>{r.display_name||r.email}</option>)}</select></label><label className="form-control"><span>Daily target</span><input type="number" min="0" value={assignment.dailyTarget} onChange={e=>setAssignment({...assignment,dailyTarget:e.target.value})}/></label><label className="form-control"><span>Total target</span><input type="number" min="0" value={assignment.totalTarget} onChange={e=>setAssignment({...assignment,totalTarget:e.target.value})}/></label><label className="form-control"><span>Status</span><select value={assignment.status} onChange={e=>setAssignment({...assignment,status:e.target.value})}>{['ACTIVE','PAUSED','COMPLETED','REMOVED'].map(x=><option key={x}>{x}</option>)}</select></label><label className="form-control"><span>Priority</span><select value={assignment.priority} onChange={e=>setAssignment({...assignment,priority:e.target.value})}><option value="">Use requirement priority</option>{['LOW','NORMAL','HIGH','URGENT'].map(x=><option key={x} value={x}>{x}</option>)}</select></label><label className="form-control"><span>Priority context</span><input value={assignment.priorityContext} onChange={e=>setAssignment({...assignment,priorityContext:e.target.value})} placeholder="e.g. urgent client SLA"/></label><label className="form-control"><span>Blocker type</span><input value={assignment.blockerType} onChange={e=>setAssignment({...assignment,blockerType:e.target.value})} placeholder="e.g. MANAGER_ACTION_REQUIRED"/></label><label className="form-control"><span>Blocker owner</span><select value={assignment.blockerOwnerUserId} onChange={e=>setAssignment({...assignment,blockerOwnerUserId:e.target.value})}><option value="">Unassigned</option>{list(ctx.eligible_action_owners).map(r=><option key={r.user_id} value={r.user_id}>{r.display_name||r.email} · {String(r.business_role||'').replaceAll('_',' ')}</option>)}</select></label><label className="form-control wide"><span>Blocker reason</span><input value={assignment.blockerReason} onChange={e=>setAssignment({...assignment,blockerReason:e.target.value})} placeholder="Leave blank when unblocked"/></label><label className="form-control wide"><span>Manager instructions</span><textarea rows="3" value={assignment.managerInstructions} onChange={e=>setAssignment({...assignment,managerInstructions:e.target.value})}/></label></div><button className="primary-action" onClick={saveAssignment} disabled={!assignment.recruiterUserId}>Save assignment</button></div>
     </div>
     <div className="rx-assignment-list">{list(ctx.assignments).map(a=><div key={a.id}><b>{a.recruiter_name||a.recruiter_user_id}</b><span>{a.assignment_status} · daily {a.daily_target} · total {a.total_submission_target||a.total_target||0} · {a.priority||'requirement priority'}</span><small>{a.blocker_reason?'Blocked: '+a.blocker_reason:(a.manager_instructions||a.priority_context||'No manager instructions')}</small></div>)}</div>
   </section>:null}

   <CommunicationTimeline jobId={jobId}/>
   {intakeOpen?<div className="modal-backdrop"><section className="ats-modal rx-intake-modal"><div className="drawer-head"><div><span className="page-kicker">Fast sourcing intake</span><h2>Add sourced candidate</h2><p>Search internal talent first, or create the minimum candidate record. Candidate intelligence is not run in Step 3.</p></div><button onClick={()=>setIntakeOpen(false)}>×</button></div>
     <div className="rx-internal-search"><input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Search existing candidate, email, title or company"/><button onClick={searchExisting} disabled={searching||search.trim().length<2}>{searching?'Searching…':'Search internal talent'}</button></div>
     {searchRows.length?<div className="rx-search-results">{searchRows.map(r=><article key={r.id}><div><b>{r.full_name}</b><span>{[r.current_title,r.current_company].filter(Boolean).join(' · ')}</span><small>{r.email||r.phone||'Contact hidden until authorized'}{r.already_on_requirement?' · already on this requirement':!r.reusable_without_manager?' · manager review required to reuse':''}</small></div>{r.reusable_without_manager?<button onClick={()=>chooseExisting(r)}>Reuse</button>:<span className="status neutral">Manager review</span>}</article>)}</div>:null}
     {intake.candidateId?<div className="rx-reuse-banner"><b>Reusing existing candidate</b><span>{intake.fullName} · {intake.email||intake.phone}</span><button onClick={()=>setIntake({...intake,candidateId:'',sourceType:''})}>Create new instead</button></div>:null}
     {!intake.candidateId?<div className="form-grid two"><label className="form-control"><span>Full name *</span><input value={intake.fullName} onChange={e=>setIntake({...intake,fullName:e.target.value})}/></label><label className="form-control"><span>Email</span><input type="email" value={intake.email} onChange={e=>setIntake({...intake,email:e.target.value})}/></label><label className="form-control"><span>Phone</span><input value={intake.phone} onChange={e=>setIntake({...intake,phone:e.target.value})}/></label><label className="form-control"><span>Current title</span><input value={intake.currentTitle} onChange={e=>setIntake({...intake,currentTitle:e.target.value})}/></label><label className="form-control"><span>Current company</span><input value={intake.currentCompany} onChange={e=>setIntake({...intake,currentCompany:e.target.value})}/></label></div>:null}
     <div className="form-grid two"><label className="form-control"><span>Source *</span><select value={intake.sourceType} onChange={e=>setIntake({...intake,sourceType:e.target.value})}><option value="">Select source</option>{SOURCES.map(x=><option key={x} value={x}>{x.replaceAll('_',' ')}</option>)}</select></label><label className="form-control"><span>Public profile / source reference</span><input value={intake.sourceReference} onChange={e=>setIntake({...intake,sourceReference:e.target.value})} placeholder="Profile URL, referral reference, etc."/></label><label className="form-control wide"><span>Sourcing notes</span><textarea rows="3" value={intake.sourcingNotes} onChange={e=>setIntake({...intake,sourcingNotes:e.target.value})}/></label><label className="form-control wide"><span>Resume · optional</span><input ref={fileRef} type="file" accept=".pdf,.docx,.txt,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document,text/plain" onChange={e=>setResume(e.target.files?.[0]||null)}/><small>Stored privately. Existing local parsing may extract text, but Step-4 fit scoring is not run.</small></label></div>
     <div className="modal-actions"><span>{state==='saving'?'Saving…':''}</span><button className="primary-action" onClick={intakeCandidate} disabled={state==='saving'||!intake.sourceType||(!intake.candidateId&&(!intake.fullName||(!intake.email&&!intake.phone)))}>Add to requirement</button></div>
   </section></div>:null}
 </div>;
}
