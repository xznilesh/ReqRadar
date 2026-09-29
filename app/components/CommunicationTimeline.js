'use client';
import { useEffect,useRef,useState } from 'react';
export default function CommunicationTimeline({jobId,candidateId=null}){
 const [data,setData]=useState(null),[body,setBody]=useState(''),[type,setType]=useState('NOTE'),[status,setStatus]=useState('');const key=useRef(null);
 async function request(entry=null){const r=await fetch('/api/ats',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({action:'communicationTimeline',payload:{jobId,candidateId,entry}})});const d=await r.json();if(!r.ok||!d.ok)throw Error(d.error||'timeline_unavailable');return d}
 useEffect(()=>{let active=true;request().then(d=>{if(active)setData(d)}).catch(()=>{if(active)setStatus('Timeline unavailable')});return()=>{active=false}},[jobId,candidateId]);
 async function save(){setStatus('Saving…');try{key.current||=crypto.randomUUID();const d=await request({id:key.current,type,body});setData(d);setBody('');key.current=null;setStatus('Communication recorded')}catch(e){setStatus(e.message)}}
 return <section className="profile-section"><h3>Communication timeline</h3><p>Shared history for this requirement, candidate and client. Email and messaging entries record conversations; they do not send messages.</p>
 <div className="form-grid two"><label className="form-control"><span>Channel</span><select value={type} onChange={e=>{setType(e.target.value);key.current=null}}>{['NOTE','CALL','EMAIL','MEETING','LINKEDIN','WHATSAPP','SMS'].map(x=><option key={x}>{x}</option>)}</select></label><label className="form-control wide"><span>Conversation / note</span><textarea value={body} maxLength={4000} rows={3} onChange={e=>{setBody(e.target.value);key.current=null}}/></label></div>
 <button className="primary-action" disabled={!body.trim()||status==='Saving…'} onClick={save}>Log communication</button><p role="status">{status}</p>
 {data?.lastContactAt?<p>Last contact: {new Date(data.lastContactAt).toLocaleString()}</p>:null}
 <div className="crm-activity-list">{data?.rows?.map(r=><article key={r.id}><div><b>{r.activity_type} · {r.actor_name||'Team'}</b><p>{r.body}</p><small>{new Date(r.occurred_at).toLocaleString()}</small></div></article>)}</div></section>
}
