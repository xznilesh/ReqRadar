'use client';
import { useState } from 'react';
export default function CandidateOwnershipPanel({candidateId,initial}){
 const [data,setData]=useState(initial),[owner,setOwner]=useState(initial?.ownerUserId||''),[reason,setReason]=useState(''),[status,setStatus]=useState('');
 if(!data?.ok)return null;
 async function save(){setStatus('Saving…');try{const r=await fetch('/api/ats',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action:'transferCandidateOwner',payload:{candidateId,ownerUserId:owner,expectedOwnerUserId:data.ownerUserId,reason}})});const d=await r.json();if(!r.ok||!d.ok)throw Error(d.error||'transfer_failed');setData({...data,ownerUserId:d.ownerUserId||owner});setReason('');setStatus('Ownership transferred and audited. Existing requirement assignments are retained.')}catch(e){setStatus(e.message)}}
 return <section className="profile-section"><h3>Candidate ownership</h3><div className="form-grid two"><label className="form-control"><span>Owner</span><select value={owner} onChange={e=>setOwner(e.target.value)}><option value="">Choose recruiter</option>{data.members.map(m=><option key={m.id} value={m.id}>{m.name||m.id}</option>)}</select></label><label className="form-control"><span>Transfer reason</span><input value={reason} onChange={e=>setReason(e.target.value)} maxLength={1000}/></label></div><button className="primary-action" disabled={!owner||owner===data.ownerUserId||reason.trim().length<5||status==='Saving…'} onClick={save}>Transfer ownership</button><p role="status">{status}</p></section>
}
