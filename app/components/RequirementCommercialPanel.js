'use client';
import { useState } from 'react';
export default function RequirementCommercialPanel({jobId,initial}){
 const [form,setForm]=useState(initial),[status,setStatus]=useState('');
 if(!form?.ok)return null;
 async function save(){setStatus('Saving…');try{const r=await fetch('/api/ats',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action:'requirementCommercial',payload:{jobId,values:{...form,expectedUpdatedAt:form.updatedAt}}})});const d=await r.json();if(!r.ok||!d.ok)throw Error(d.error||'save_failed');setForm(d);setStatus('Saved. Regenerate any submission pack before AM approval.')}catch(e){setStatus(e.message)}}
 return <section className="profile-section"><h3>Client commercial terms & presentation</h3><div className="form-grid two">
 <label className="form-control"><span>Client bill rate / fee</span><input type="number" min="0" step="0.01" value={form.billRate??''} onChange={e=>setForm({...form,billRate:e.target.value})}/></label>
 <label className="form-control"><span>Currency</span><input maxLength={3} value={form.currency||''} onChange={e=>setForm({...form,currency:e.target.value.toUpperCase()})}/></label>
 <label className="form-control"><span>Billing period</span><select value={form.period||''} onChange={e=>setForm({...form,period:e.target.value})}><option value="">Choose</option>{['HOURLY','DAILY','WEEKLY','MONTHLY','ANNUAL','FIXED'].map(x=><option key={x}>{x}</option>)}</select></label>
 <label className="form-control"><span>Client presentation</span><select value={form.presentationFormat} onChange={e=>setForm({...form,presentationFormat:e.target.value})}><option value="SUMMARY">Shortlist summary</option><option value="DETAILED">Detailed profile</option></select></label>
 <label><input type="checkbox" checked={form.includeCompensation===true} onChange={e=>setForm({...form,includeCompensation:e.target.checked})}/> Include candidate compensation in client presentation</label></div>
 <button className="primary-action" onClick={save} disabled={status==='Saving…'}>Save commercial terms</button><p role="status">{status}</p></section>
}
