'use client';
import { useEffect,useState } from 'react';
export default function ClientAccountPanel({clientId}){
 const [data,setData]=useState(null),[parent,setParent]=useState(''),[status,setStatus]=useState('');
 async function request(action,payload){const r=await fetch('/api/crm',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action,payload})});const d=await r.json();if(!r.ok||!d.ok)throw Error(d.error||'account_unavailable');return d}
 async function load(){const d=await request('clientStaffingContext',{clientId});setData(d);setParent(d.parentClientId||'')}
 useEffect(()=>{load().catch(e=>setStatus(e.message))},[clientId]);
 async function save(){setStatus('Saving…');try{await request('setAccountParent',{clientId,parentClientId:parent,expectedUpdatedAt:data.updatedAt});await load();setStatus('Account relationship saved')}catch(e){setStatus(e.message)}}
 if(!data)return status==='forbidden'?null:<p role="status">{status||'Loading account history…'}</p>;
 return <section className="crm-card"><h3>Client → Account → Requirements</h3>{data.canEditAccount?<><label className="form-control"><span>Parent client company</span><select value={parent} onChange={e=>setParent(e.target.value)}><option value="">This is the client company / its own account</option>{data.parentChoices.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label><button onClick={save} disabled={status==='Saving…'}>Save account relationship</button></>:null}<p role="status">{status}</p>{data.accounts.length?<p>Operating accounts: {data.accounts.map(c=>c.name).join(', ')}</p>:null}
 <h4>Submission history</h4><div className="crm-compact-list">{data.submissions.map(s=><article key={s.id}><div><b>{s.candidate_name} · {s.job_title}</b><small>{s.workflow_status?.replaceAll('_',' ')}{s.client_submitted_at?' · '+new Date(s.client_submitted_at).toLocaleDateString():''}</small></div></article>)}</div>
 <h4>Interviews</h4><div className="crm-compact-list">{data.interviews.map(i=><article key={i.id}><div><b>{i.candidate_name} · {i.job_title}</b><small>{i.status} · {new Date(i.scheduled_at).toLocaleString()}</small></div></article>)}</div></section>
}
