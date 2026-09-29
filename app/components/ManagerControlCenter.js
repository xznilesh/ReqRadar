'use client';

import { useEffect,useMemo,useState } from 'react';
import { staffingConversionRatios } from '@/lib/manager-control.mjs';
import StaffingRevenuePanel from '@/app/components/StaffingRevenuePanel';
import Link from 'next/link';

const list=(v)=>Array.isArray(v)?v:[];
const n=(v)=>Number(v||0);
const pretty=(v)=>String(v||'').replaceAll('_',' ').toLowerCase().replace(/\b\w/g,m=>m.toUpperCase());
const pct=(done,planned)=>planned>0?Math.min(100,Math.round(done/planned*100)):0;
const when=(value)=>value?new Date(value).toLocaleString():'—';

async function getJson(url){
  const res=await fetch(url,{cache:'no-store'});
  const data=await res.json().catch(()=>({error:'invalid_response'}));
  if(!res.ok)throw new Error(data?.error||'request_failed');
  return data;
}
async function post(body){
  const res=await fetch('/api/manager-control',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
  const data=await res.json().catch(()=>({error:'invalid_response'}));
  if(!res.ok)throw new Error(data?.error||'request_failed');
  return data;
}
function Metric({label,value,sub,href}){
  const body=<div className="mc-metric"><span>{label}</span><b>{value}</b>{sub?<small>{sub}</small>:null}</div>;
  return href?<Link href={href} className="mc-metric-link">{body}</Link>:body;
}
function Health({value}){
  const key=String(value||'HEALTHY');
  return <span className={'mc-health '+key.toLowerCase()}>{pretty(key)}</span>;
}
function Severity({value}){
  const key=String(value||'INFO');
  return <span className={'mc-severity '+key.toLowerCase()}>{pretty(key)}</span>;
}

export default function ManagerControlCenter({initialHome,initialNotifications,initialAnalytics}){
  const[home,setHome]=useState(initialHome||{});
  const[notifications,setNotifications]=useState(initialNotifications||{notifications:[]});
  const[analytics,setAnalytics]=useState(initialAnalytics||{funnel:{},sources:[]});
  const[state,setState]=useState('idle');
  const[message,setMessage]=useState('');
  const[lastRefresh,setLastRefresh]=useState(initialHome?.refreshedAt||null);
  const[filters,setFilters]=useState({from:'',to:'',clientId:'',jobId:'',recruiterId:'',accountManagerId:'',source:''});

  async function refresh({silent=false}={}){
    if(!silent){setState('loading');setMessage('')}
    try{
      const [h,nf,an]=await Promise.all([
        getJson('/api/manager-control?mode=home'),
        getJson('/api/manager-control?mode=notifications'),
        getJson('/api/manager-control?mode=analytics')
      ]);
      setHome(h);setNotifications(nf);setAnalytics(an);setLastRefresh(h.refreshedAt||new Date().toISOString());
      if(!silent){setState('saved');setMessage('Control center refreshed from canonical data.')}
    }catch(e){if(!silent){setState('error');setMessage(e.message)}}
  }
  useEffect(()=>{
    const timer=setInterval(()=>refresh({silent:true}),30000);
    return()=>clearInterval(timer);
  },[]);
  async function refreshAnalytics(){
    setState('loading');setMessage('');
    try{
      const qs=new URLSearchParams({mode:'analytics'});
      for(const [k,v] of Object.entries(filters))if(v)qs.set(k,v);
      const an=await getJson('/api/manager-control?'+qs.toString());
      setAnalytics(an);setState('saved');setMessage('Analytics cohort updated.');
    }catch(e){setState('error');setMessage(e.message)}
  }
  async function runAutomation(){
    setState('loading');setMessage('');
    try{const r=await post({action:'manualRun'});setMessage(`Automation run complete · detected ${r.detected||0} · resolved ${r.resolved||0}`);await refresh({silent:true});setState('saved')}
    catch(e){setState('error');setMessage(e.message)}
  }
  async function alertAction(alertId,alertAction){
    setState('loading');setMessage('');
    try{await post({action:'alertAction',alertId,alertAction});await refresh({silent:true});setState('saved');setMessage(`Alert ${alertAction.toLowerCase()}d.`)}
    catch(e){setState('error');setMessage(e.message)}
  }

  const canControl=['OWNER','ADMIN','RECRUITMENT_MANAGER'].includes(String(home.role||''));
  const t=home.today||{};
  const options=home.filterOptions||{};
  const reqs=list(home.requirements),recruiters=list(home.recruiters),exceptions=list(home.exceptions);
  const funnel=analytics.funnel||{};
  const ratios=staffingConversionRatios(funnel);
  const maxFunnel=Math.max(1,...['sourced','screened','qualified','internallySubmitted','amApproved','clientSubmitted','interviewed','offered','joined'].map(k=>n(funnel[k])));
  const activeNotifications=list(notifications.notifications);
  const majorRisks=exceptions.filter(x=>x.severity==='URGENT').length;
  const managerSummary=useMemo(()=>[
    n(t.requirementsAtRisk)?`${n(t.requirementsAtRisk)} requirement(s) at risk or blocked.`:'No currently detected at-risk/blocked requirement.',
    n(t.remainingSubmissionGap)?`${n(t.remainingSubmissionGap)} valid submission(s) remain against today's plan.`:"Today's planned submission target is currently covered.",
    n(t.amReviewsPending)?`${n(t.amReviewsPending)} submission(s) waiting for AM review.`:'No AM review backlog currently detected.',
    n(t.clientFeedbackPending)?`${n(t.clientFeedbackPending)} client feedback follow-up(s) pending.`:'No overdue client-feedback alert currently open.'
  ],[t]);

  return <div className="manager-control">
    <div className="page-heading">
      <div><span className="page-kicker">Step 8 · real-time operational control</span><h1>Manager Control Center</h1><p>Deterministic targets, health, exceptions and next operational actions. No hidden employee score.</p></div>
      <div className="mc-heading-actions"><Link className="ghost-action" href="/notifications">Notification center</Link><button className="ghost-action" onClick={()=>refresh()} disabled={state==='loading'}>Refresh</button>{canControl?<button className="primary-action" onClick={runAutomation} disabled={state==='loading'}>Run controls now</button>:null}</div>
    </div>

    {message?<div className={state==='error'?'save-error profile-error':'pipeline-feedback success'} role="status">{message}</div>:null}
    <div className="mc-freshness">Business day: <b>{home.businessDate||'—'}</b> · Timezone: <b>{home.timezone||'UTC'}</b> · Last refresh: <b>{when(lastRefresh)}</b> · Auto-refresh: 30s</div>

    <section className="mc-today" aria-label="Today operational metrics">
      <Metric label="Active requirements" value={n(t.activeRequirements)}/>
      <Metric label="Planned submissions" value={n(t.plannedSubmissions)}/>
      <Metric label="Valid submissions" value={n(t.validSubmissions)} sub={`${pct(n(t.validSubmissions),n(t.plannedSubmissions))}% of plan`}/>
      <Metric label="Remaining gap" value={n(t.remainingSubmissionGap)}/>
      <Metric label="Requirements at risk" value={n(t.requirementsAtRisk)}/>
      <Metric label="Recruiters below target" value={n(t.recruitersBelowTarget)}/>
      <Metric label="Overdue actions" value={n(t.overdueRecruiterActions)}/>
      <Metric label="AM reviews pending" value={n(t.amReviewsPending)}/>
      <Metric label="Client feedback pending" value={n(t.clientFeedbackPending)}/>
      <Metric label="Interviews today" value={n(t.interviewsToday)}/>
      <Metric label="Offer actions" value={n(t.offersRequiringAction)}/>
      <Metric label="Joining actions" value={n(t.joiningsRequiringAction)}/>
    </section>

    <section className="mc-card">
      <div className="mc-section-title"><div><span className="page-kicker">Cohort filters</span><h2>Funnel & source analysis</h2></div><button className="ghost-action" onClick={refreshAnalytics} disabled={state==='loading'}>Apply filters</button></div>
      <div className="mc-filter-form">
        <label><span>From</span><input type="date" value={filters.from} onChange={e=>setFilters({...filters,from:e.target.value})}/></label>
        <label><span>To</span><input type="date" value={filters.to} onChange={e=>setFilters({...filters,to:e.target.value})}/></label>
        <label><span>Client</span><select value={filters.clientId} onChange={e=>setFilters({...filters,clientId:e.target.value})}><option value="">All clients</option>{list(options.clients).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
        <label><span>Requirement</span><select value={filters.jobId} onChange={e=>setFilters({...filters,jobId:e.target.value})}><option value="">All requirements</option>{list(options.requirements).map(x=><option key={x.id} value={x.id}>{x.title}</option>)}</select></label>
        <label><span>Recruiter</span><select value={filters.recruiterId} onChange={e=>setFilters({...filters,recruiterId:e.target.value})}><option value="">All recruiters</option>{list(options.recruiters).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
        <label><span>Account Manager</span><select value={filters.accountManagerId} onChange={e=>setFilters({...filters,accountManagerId:e.target.value})}><option value="">All AMs</option>{list(options.accountManagers).map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
        <label><span>Source</span><select value={filters.source} onChange={e=>setFilters({...filters,source:e.target.value})}><option value="">All sources</option>{list(options.sources).map(x=><option key={x} value={x}>{pretty(x)}</option>)}</select></label>
        <button onClick={()=>{setFilters({from:'',to:'',clientId:'',jobId:'',recruiterId:'',accountManagerId:'',source:''});setTimeout(()=>refresh({silent:true}),0)}}>Reset</button>
      </div>
      <p className="mc-muted">Cohort definition: applications created inside the selected time window. Stage outcomes are measured for that same cohort.</p>
    </section>

    <div className="mc-grid two">
      <section className="mc-card">
        <div className="mc-section-title"><div><span className="page-kicker">Operational summary</span><h2>What needs attention</h2></div><span className="mc-count">{majorRisks} urgent</span></div>
        <div className="mc-summary">{managerSummary.map((x,i)=><p key={i}>{x}</p>)}</div>
      </section>
      <section className="mc-card">
        <div className="mc-section-title"><div><span className="page-kicker">Bottleneck</span><h2>{pretty(analytics.bottleneck||'NO_DOMINANT_BOTTLENECK')}</h2></div></div>
        <p className="mc-muted">Cohort: {analytics.cohortDefinition||'APPLICATION_CREATED_IN_WINDOW'} · {analytics.from?new Date(analytics.from).toLocaleDateString():'—'} → {analytics.to?new Date(analytics.to).toLocaleDateString():'now'}</p>
        <div className="drawer-grid">{[['Qualified → submission',ratios.submissionToQualified],['Submission → interview',ratios.interviewToSubmission],['Interview → offer',ratios.offerToInterview],['Offer → join',ratios.joinToOffer]].map(([label,value])=><div key={label}><span>{label}</span><b>{value==null?'—':value+'%'}</b></div>)}</div><div className="mc-funnel-mini">{Object.entries({
          Sourced:funnel.sourced,Screened:funnel.screened,Qualified:funnel.qualified,'Internal submit':funnel.internallySubmitted,'AM approved':funnel.amApproved,'Client submit':funnel.clientSubmitted,Interviewed:funnel.interviewed,Offered:funnel.offered,Joined:funnel.joined
        }).map(([label,value])=><div key={label}><span>{label}</span><i style={{width:`${Math.max(3,n(value)/maxFunnel*100)}%`}}/><b>{n(value)}</b></div>)}</div>
      </section>
    </div>

    <section className="mc-card">
      <div className="mc-section-title"><div><span className="page-kicker">Exception queue</span><h2>What? Why? Who owns it? What next?</h2></div><Link href="/notifications" className="ghost-action">All notifications</Link></div>
      {exceptions.length?<div className="mc-exception-list">{exceptions.map(x=><article key={x.id}>
        <div className="mc-exception-head"><Severity value={x.severity}/><b>{pretty(x.category)}</b><span>{x.owner||'Unassigned'}</span><small>{Number(x.age_hours||0).toFixed(1)}h old</small></div>
        <h3>{x.reason_summary}</h3>
        <p>{x.recommended_action}</p>
        <div className="mc-reasons">{list(x.reason_codes).map(r=><span key={r}>{pretty(r)}</span>)}</div>
        <div className="mc-row-actions">{x.job_id?<Link href={`/manager/requirements/${x.job_id}`}>Open requirement</Link>:null}<button onClick={()=>alertAction(x.id,'ACKNOWLEDGE')}>Acknowledge</button><button onClick={()=>alertAction(x.id,'DISMISS')}>Dismiss</button></div>
      </article>)}</div>:<div className="ats-empty">No open manager exceptions.</div>}
    </section>

    <section className="mc-card">
      <div className="mc-section-title"><div><span className="page-kicker">Requirement health</span><h2>Priority requirements</h2></div></div>
      {reqs.length?<div className="mc-table">
        <div className="mc-tr head"><span>Requirement</span><span>Health</span><span>Target</span><span>Pipeline</span><span>Deadline</span><span>Next action</span></div>
        {reqs.map(r=><Link className="mc-tr" key={r.id} href={`/manager/requirements/${r.id}`}><span><b>{r.title}</b><small>{r.client_name||'Client not set'} · {pretty(r.priority)}</small></span><span><Health value={r.health_status}/>{list(r.reason_codes).slice(0,2).map(x=><small key={x}>{pretty(x)}</small>)}</span><span><b>{n(r.valid_submissions_today)}/{n(r.submission_target_daily)}</b><small>{n(r.remaining_target)} remaining</small></span><span><b>{n(r.pipeline_count)}</b></span><span>{r.target_fill_date||'—'}</span><span>{list(r.next_actions)[0]?.text||'No immediate exception'}</span></Link>)}
      </div>:<div className="ats-empty">No active requirements.</div>}
    </section>

    <div className="mc-grid two">
      <section className="mc-card">
        <div className="mc-section-title"><div><span className="page-kicker">Recruiter facts</span><h2>Workload & target progress</h2></div></div>
        {recruiters.length?<div className="mc-recruiters">{recruiters.map(r=><article key={r.user_id}><div><b>{r.recruiter}</b><small>{n(r.active_requirements)} active roles · {n(r.candidate_pipeline)} pipeline</small></div><div><span>Target</span><b>{n(r.valid_submissions)}/{n(r.daily_target)}</b><small>{n(r.remaining_target)} remaining</small></div><div><span>Screened / Qualified</span><b>{n(r.screenings_completed)} / {n(r.qualified_candidates)}</b></div><div><span>Overdue follow-ups</span><b>{n(r.overdue_followups)}</b></div><div><span>Submit → interview</span><b>{n(r.client_submissions_total)?Math.round(n(r.interviews_total)/n(r.client_submissions_total)*100):0}%</b></div></article>)}</div>:<div className="ats-empty">No active recruiter assignments.</div>}
      </section>
      <section className="mc-card">
        <div className="mc-section-title"><div><span className="page-kicker">AM control</span><h2>Quality gate & client feedback</h2></div></div>
        <dl className="mc-definition"><div><dt>Waiting review</dt><dd>{n(home.amControl?.waitingReview)}</dd></div><div><dt>Returned</dt><dd>{n(home.amControl?.returned)}</dd></div><div><dt>Approved</dt><dd>{n(home.amControl?.approved)}</dd></div><div><dt>Client feedback pending</dt><dd>{n(home.amControl?.clientFeedbackPending)}</dd></div></dl>
      </section>
    </div>

    <div className="mc-grid two">
      <section className="mc-card"><div className="mc-section-title"><div><span className="page-kicker">Source performance</span><h2>Conversion, not volume alone</h2></div></div>{list(analytics.sources).length?<div className="mc-source-list">{list(analytics.sources).map(s=><article key={s.source}><b>{pretty(s.source)}</b><span>{n(s.candidates)} candidates</span><span>{n(s.qualified)} qualified</span><span>{n(s.client_submissions)} submitted</span><span>{n(s.interviews)} interviews</span><span>{n(s.offers)} offers</span><span>{n(s.joinings)} joined</span></article>)}</div>:<div className="ats-empty">No source cohort data in the selected period.</div>}</section>
      <section className="mc-card"><div className="mc-section-title"><div><span className="page-kicker">Near-term control</span><h2>Interviews · offers · joinings</h2></div></div><div className="mc-upcoming"><h3>Interviews</h3>{list(home.interviews).slice(0,6).map(x=><p key={x.id}><b>{x.candidate_name}</b> · {x.job_title}<span>{when(x.scheduled_at)}</span></p>)}<h3>Offers</h3>{list(home.offers).slice(0,5).map(x=><p key={x.id}><b>{x.candidate_name}</b> · {x.job_title}<span>{pretty(x.status)}</span></p>)}<h3>Joinings</h3>{list(home.joinings).slice(0,5).map(x=><p key={x.id}><b>{x.candidate_name}</b> · {x.job_title}<span>{x.start_date||'—'}</span></p>)}</div></section>
    </div>

    <section className="mc-card mc-owner-view">
      <div className="mc-section-title"><div><span className="page-kicker">Owner / executive view</span><h2>Concise operational pulse</h2></div></div>
      <div className="mc-owner-grid"><Metric label="Active requirements" value={n(t.activeRequirements)}/><Metric label="Target achievement" value={`${pct(n(t.validSubmissions),n(t.plannedSubmissions))}%`}/><Metric label="Interviews today" value={n(t.interviewsToday)}/><Metric label="Open urgent risks" value={majorRisks}/><Metric label="Offers needing action" value={n(t.offersRequiringAction)}/><Metric label="Joinings needing action" value={n(t.joiningsRequiringAction)}/></div>
    </section>
    <span className="sr-only">Open notifications: {activeNotifications.length}</span>
  <StaffingRevenuePanel filters={{from:filters.from,to:filters.to,clientId:filters.clientId,recruiterId:filters.recruiterId,accountManagerId:filters.accountManagerId}}/></div>;
}
