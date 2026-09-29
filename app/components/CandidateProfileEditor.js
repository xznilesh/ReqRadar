'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';

const SENIORITY=['INTERN','ENTRY','ASSOCIATE','MID','SENIOR','LEAD','MANAGER','SENIOR_MANAGER','HEAD','DIRECTOR','SENIOR_DIRECTOR','VP','SVP','EVP','C_LEVEL','BOARD'];
const AVAILABILITY=['UNKNOWN','AVAILABLE_NOW','AVAILABLE_SOON','PASSIVE','NOT_AVAILABLE'];
const WORKPLACE=['','ONSITE','HYBRID','REMOTE','FLEXIBLE'];
const EMPLOYMENT=['','FULL_TIME','PART_TIME','PERMANENT','CONTRACT','TEMPORARY','FREELANCE','INTERNSHIP'];
const CONSENT=['UNKNOWN','PENDING','GRANTED','WITHDRAWN'];
const RETENTION=['ACTIVE','REVIEW','HOLD','DELETE_REQUESTED'];

function listText(value){return Array.isArray(value)?value.map((x)=>typeof x==='string'?x:(x?.label||x?.name||x?.text||JSON.stringify(x))).filter(Boolean).join('\n'):''}
function parseLines(value){return String(value||'').split(/\n|,/).map((x)=>x.trim()).filter(Boolean).filter((x,i,a)=>a.findIndex((y)=>y.toLowerCase()===x.toLowerCase())===i)}

async function ats(action,payload){const res=await fetch('/api/ats',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,payload})});const data=await res.json().catch(()=>({error:'invalid_response'}));if(!res.ok)throw new Error(data?.error||'request_failed');return data}

export default function CandidateProfileEditor({profile,countries=[],timezones=[]}){
 const router=useRouter();
 const[form,setForm]=useState({...profile,skillsText:listText(profile.skills),languagesText:listText(profile.languages),educationText:listText(profile.education),certificationsText:listText(profile.certifications),desiredLocationsText:listText(profile.desiredLocations),workAuthorizationText:listText(profile.workAuthorizationSummary),tagsText:listText(profile.tags)});
 const[state,setState]=useState('idle');const[error,setError]=useState('');
 const zones=useMemo(()=>timezones.filter((z)=>!form.countryCode||z.country_code===form.countryCode),[timezones,form.countryCode]);
 function set(field,value){setForm((f)=>({...f,[field]:value}));if(state!=='saving')setState('dirty')}
 async function save(){setState('saving');setError('');const payload={...form,skills:parseLines(form.skillsText),languages:parseLines(form.languagesText),education:parseLines(form.educationText),certifications:parseLines(form.certificationsText),desiredLocations:parseLines(form.desiredLocationsText),workAuthorizationSummary:parseLines(form.workAuthorizationText),tags:parseLines(form.tagsText)};try{await ats('updateCandidateProfile',{candidateId:profile.id,profile:payload});setState('saved');router.refresh()}catch(e){setState('error');setError(e.message==='possible_duplicate'?'Another active candidate already uses this email or phone. Review duplicates before changing the primary contact.':e.message||'Could not save candidate profile.')}}
 return <div className="candidate-profile-editor">
   <div className="profile-editor-head"><div><span className="page-kicker">Candidate 360</span><h2>Profile & recruitment preferences</h2><p>Full-detail editor. List views stay lightweight; this data is loaded only when you open the candidate.</p></div><div className={`profile-save-state ${state}`} aria-live="polite">{state==='saving'?'Saving…':state==='saved'?'Saved':state==='dirty'?'Unsaved changes':state==='error'?'Save failed':'Up to date'}</div></div>
   {error?<div className="save-error profile-error" role="alert">{error}</div>:null}
   <section className="profile-section"><h3>Identity & contact</h3><div className="form-grid two">
     <label className="form-control"><span>Full name *</span><input value={form.fullName||''} onChange={(e)=>set('fullName',e.target.value)}/></label>
     <label className="form-control"><span>Preferred name</span><input value={form.preferredName||''} onChange={(e)=>set('preferredName',e.target.value)}/></label>
     <label className="form-control wide"><span>Professional headline</span><input value={form.headline||''} onChange={(e)=>set('headline',e.target.value)}/></label>
     <label className="form-control"><span>Primary email</span><input type="email" value={form.email||''} onChange={(e)=>set('email',e.target.value)}/></label>
     <label className="form-control"><span>Secondary email</span><input type="email" value={form.secondaryEmail||''} onChange={(e)=>set('secondaryEmail',e.target.value)}/></label>
     <label className="form-control"><span>Primary phone</span><input value={form.phone||''} onChange={(e)=>set('phone',e.target.value)}/></label>
     <label className="form-control"><span>Secondary phone</span><input value={form.secondaryPhone||''} onChange={(e)=>set('secondaryPhone',e.target.value)}/></label>
   </div></section>
   <section className="profile-section"><h3>Role & experience</h3><div className="form-grid two">
     <label className="form-control"><span>Current title</span><input value={form.currentTitle||''} onChange={(e)=>set('currentTitle',e.target.value)}/></label>
     <label className="form-control"><span>Current company</span><input value={form.currentCompany||''} onChange={(e)=>set('currentCompany',e.target.value)}/></label>
     <label className="form-control"><span>Job function</span><input value={form.jobFunction||''} onChange={(e)=>set('jobFunction',e.target.value)} placeholder="Engineering, Finance, Sales…"/></label>
     <label className="form-control"><span>Seniority</span><select value={form.seniority||''} onChange={(e)=>set('seniority',e.target.value)}><option value="">Unspecified</option>{SENIORITY.map((v)=><option key={v} value={v}>{v.replaceAll('_',' ')}</option>)}</select></label>
     <label className="form-control"><span>Total experience (years)</span><input type="number" min="0" step="0.5" value={form.experienceYears??''} onChange={(e)=>set('experienceYears',e.target.value)}/></label>
     <label className="form-control"><span>Relevant experience (years)</span><input type="number" min="0" step="0.5" value={form.relevantExperienceYears??''} onChange={(e)=>set('relevantExperienceYears',e.target.value)}/></label>
     <label className="form-control wide"><span>Skills</span><textarea rows="4" value={form.skillsText||''} onChange={(e)=>set('skillsText',e.target.value)} placeholder="One skill per line, or comma separated"/></label>
     <label className="form-control"><span>Languages</span><textarea rows="4" value={form.languagesText||''} onChange={(e)=>set('languagesText',e.target.value)} placeholder="English\nGerman\nArabic"/></label>
     <label className="form-control"><span>Certifications</span><textarea rows="4" value={form.certificationsText||''} onChange={(e)=>set('certificationsText',e.target.value)} placeholder="One certification per line"/></label>
     <label className="form-control wide"><span>Education</span><textarea rows="4" value={form.educationText||''} onChange={(e)=>set('educationText',e.target.value)} placeholder="Degree / institution entries, one per line"/></label>
   </div></section>
   <section className="profile-section"><h3>Location & global mobility</h3><div className="form-grid two">
     <label className="form-control"><span>City</span><input value={form.city||''} onChange={(e)=>set('city',e.target.value)}/></label>
     <label className="form-control"><span>Region / state</span><input value={form.region||''} onChange={(e)=>set('region',e.target.value)}/></label>
     <label className="form-control"><span>Country</span><select value={form.countryCode||''} onChange={(e)=>{setForm((f)=>({...f,countryCode:e.target.value,timezone:''}));setState('dirty')}}><option value="">Select</option>{countries.map((c)=><option key={c.country_code} value={c.country_code}>{c.country_name}</option>)}</select></label>
     <label className="form-control"><span>IANA timezone</span><select value={form.timezone||''} onChange={(e)=>set('timezone',e.target.value)}><option value="">Select</option>{zones.map((z)=><option key={z.timezone_id} value={z.timezone_id}>{z.display_name} · {z.timezone_id}</option>)}</select></label>
     <label className="form-control"><span>Workplace preference</span><select value={form.workplacePreference||''} onChange={(e)=>set('workplacePreference',e.target.value)}>{WORKPLACE.map((v)=><option key={v||'none'} value={v}>{v?v:'Unspecified'}</option>)}</select></label>
     <label className="form-control"><span>Relocation preference</span><input value={form.relocationPreference||''} onChange={(e)=>set('relocationPreference',e.target.value)} placeholder="Open, local only, specific markets…"/></label>
     <label className="form-control wide"><span>Desired locations</span><textarea rows="3" value={form.desiredLocationsText||''} onChange={(e)=>set('desiredLocationsText',e.target.value)} placeholder="London\nDubai\nRemote UK"/></label>
     <label className="form-control wide"><span>Work authorization / sponsorship notes</span><textarea rows="3" value={form.workAuthorizationText||''} onChange={(e)=>set('workAuthorizationText',e.target.value)} placeholder="UK unrestricted\nUAE sponsorship required"/></label>
   </div></section>
   <section className="profile-section"><h3>Availability & compensation</h3><div className="form-grid two">
     <label className="form-control"><span>Availability</span><select value={form.availabilityStatus||'UNKNOWN'} onChange={(e)=>set('availabilityStatus',e.target.value)}>{AVAILABILITY.map((v)=><option key={v} value={v}>{v.replaceAll('_',' ')}</option>)}</select></label>
     <label className="form-control"><span>Notice period (days)</span><input type="number" min="0" value={form.noticePeriodDays??''} onChange={(e)=>set('noticePeriodDays',e.target.value)}/></label>
     <label className="form-control"><span>Employment preference</span><select value={form.employmentPreference||''} onChange={(e)=>set('employmentPreference',e.target.value)}>{EMPLOYMENT.map((v)=><option key={v||'none'} value={v}>{v?v.replaceAll('_',' '):'Unspecified'}</option>)}</select></label>
     <label className="form-control"><span>Expected compensation / rate</span><input type="number" min="0" value={form.salaryExpected??''} onChange={(e)=>set('salaryExpected',e.target.value)}/></label>
     <label className="form-control"><span>Pay period</span><select value={form.salaryPeriod||''} onChange={e=>set('salaryPeriod',e.target.value)}><option value="">Not confirmed</option>{['HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL'].map(p=><option key={p}>{p}</option>)}</select></label>
     <label className="form-control"><span>Currency</span><input maxLength="3" value={form.salaryCurrency||''} onChange={(e)=>set('salaryCurrency',e.target.value.toUpperCase())} placeholder="GBP"/></label>
     <label className="form-control wide"><span>Tags</span><textarea rows="3" value={form.tagsText||''} onChange={(e)=>set('tagsText',e.target.value)} placeholder="Priority\nJava\nImmediately available"/></label>
   </div></section>
   <section className="profile-section profile-governance"><h3>Privacy & lifecycle</h3><div className="form-grid two">
     <label className="form-control"><span>Consent status</span><select value={form.consentStatus||'UNKNOWN'} onChange={(e)=>set('consentStatus',e.target.value)}>{CONSENT.map((v)=><option key={v} value={v}>{v}</option>)}</select></label>
     <label className="form-control"><span>Retention status</span><select value={form.retentionStatus||'ACTIVE'} onChange={(e)=>set('retentionStatus',e.target.value)}>{RETENTION.map((v)=><option key={v} value={v}>{v.replaceAll('_',' ')}</option>)}</select></label>
   </div><p className="profile-policy-note">These are operational controls, not automated legal determinations. Region-specific retention and privacy policies can be layered on later.</p></section>
   <div className="profile-sticky-actions"><a className="ghost-action" href="/candidates">← Candidates</a><button className="primary-action" disabled={state==='saving'||!form.fullName||(!form.email&&!form.phone)} onClick={save}>{state==='saving'?'Saving…':'Save candidate profile'}</button></div>
 </div>
}
