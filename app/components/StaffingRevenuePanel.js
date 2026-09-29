'use client';
import { useEffect,useState } from 'react';
export default function StaffingRevenuePanel({clientId='',filters={}}){
 const [data,setData]=useState(null),[error,setError]=useState('');
 const query=new URLSearchParams({mode:'staffingAnalytics',...Object.fromEntries(Object.entries({...filters,clientId:clientId||filters.clientId||''}).filter(([,v])=>v))}).toString();
 useEffect(()=>{let active=true;setData(null);setError('');fetch('/api/manager-control?'+query,{cache:'no-store'}).then(async r=>{const d=await r.json();if(!r.ok||!d.ok)throw Error(d.error||'revenue_unavailable');if(active)setData(d)}).catch(e=>{if(active)setError(e.message)});return()=>{active=false}},[query]);
 if(error==='forbidden')return null;
 const t=data?.timing||{};
 return <section className="crm-card"><h3>Placement revenue & delivery</h3>{error?<p role="status">Revenue unavailable: {error}</p>:!data?<p>Loading…</p>:<><p>{data.basis}</p><p>Filters: date, client, recruiter and account manager. Requirement and source filters apply to the funnel above. Timing uses requirements created in the period; recruiter selection filters their submission and joining events.</p><div className="drawer-grid"><div><span>Requirements</span><b>{t.requirements??'—'}</b></div><div><span>Average time to submit</span><b>{t.averageTimeToSubmitHours==null?'—':Number(t.averageTimeToSubmitHours).toFixed(1)+' hours'}</b></div><div><span>Average time to fill</span><b>{t.averageTimeToFillDays==null?'—':Number(t.averageTimeToFillDays).toFixed(1)+' days'}</b></div></div>
 <div className="ats-table-wrap"><table className="ats-table"><thead><tr><th>Client</th><th>Recruiter</th><th>Currency</th><th>Expected</th><th>Achieved</th><th>Unpriced</th></tr></thead><tbody>{data.revenue.map((r,i)=><tr key={i}><td>{r.client_name||'Unknown'}</td><td>{r.recruiter_name||'Unassigned'}</td><td>{r.currency||'Not set'}</td><td>{r.expected_revenue==null?'—':Number(r.expected_revenue).toLocaleString()}</td><td>{r.achieved_revenue==null?'—':Number(r.achieved_revenue).toLocaleString()}</td><td>{r.unpriced_count}</td></tr>)}</tbody></table></div>{!data.revenue.length?<p>No placement records in this period.</p>:null}</>}</section>
}
