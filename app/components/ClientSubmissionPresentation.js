'use client';

import { useState } from 'react';

const rows=value=>Array.isArray(value)?value:[];
function text(value){
  if(value==null||value==='')return 'Not confirmed';
  if(typeof value==='object'){
    if('value' in value)return text(value.value);
    if(Array.isArray(value))return value.map(text).join(', ');
    return value.narrative||value.reason||value.requirement||value.label||'Not confirmed';
  }
  return String(value);
}
// Accept only an already-sanitized client-facing pack. Never pass the internal pack.
export default function ClientSubmissionPresentation({pack={},defaultFormat='SUMMARY'}){
  const [format,setFormat]=useState(defaultFormat==='DETAILED'?'DETAILED':'SUMMARY');
  const summary=pack.candidateSummary||{},facts=summary.facts||summary;
  return <section className="s6-card" aria-label="Client candidate presentation">
    <div className="s6-card-head"><h3>{text(facts.name)}</h3><label>Presentation <select aria-label="Presentation format" value={format} onChange={e=>setFormat(e.target.value)}><option value="SUMMARY">Shortlist summary</option><option value="DETAILED">Detailed profile</option></select></label></div>
    <p>{summary.narrative||text(facts.currentTitle)}</p>
    <div className="s6-facts">{[
      ['Availability',pack.availability?.status||pack.availability?.availability],
      ['Notice period',pack.availability?.noticePeriodDays],
      ['Work authorization',pack.workAuthorization],
      ['Location',pack.locationWorkModel?.location],
      ['Work model',pack.locationWorkModel?.workModel],
      ...(pack.compensation?[['Expected compensation',pack.compensation]]:[])
    ].map(([label,value])=><div className="s6-fact" key={label}><span>{label}</span><b>{text(value)}</b></div>)}</div>
    <h4>Why this candidate fits</h4><ul>{rows(pack.whyCandidateFits).slice(0,format==='SUMMARY'?3:12).map((item,i)=><li key={i}>{text(item)}</li>)}</ul>
    {format==='DETAILED'?<><h4>Requirement evidence</h4><ul>{rows(pack.mustHaveMatch).map((item,i)=><li key={i}>{text(item.requirement||item.label)} — {text(item.status)}{item.reason?`: ${item.reason}`:''}</li>)}</ul><p>{text(pack.recruiterScreeningSummary)}</p></>:null}
    <h4>Gaps and points to confirm</h4><ul>{[...rows(pack.knownGaps),...rows(pack.openRisksUncertainties)].map((item,i)=><li key={i}>{text(item)}</li>)}</ul>
  </section>;
}
