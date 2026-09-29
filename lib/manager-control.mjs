export const HEALTH_STATES=Object.freeze(['HEALTHY','NEEDS_ATTENTION','AT_RISK','BLOCKED','ON_HOLD']);
export const ALERT_SEVERITIES=Object.freeze(['INFO','ATTENTION','URGENT']);
export const ALERT_STATES=Object.freeze(['OPEN','ACKNOWLEDGED','RESOLVED','DISMISSED']);

export const DEFAULT_CONTROL_THRESHOLDS=Object.freeze({
  targetAttentionHoursBeforeCutoff:4,
  targetRiskHoursBeforeCutoff:2,
  screeningAttentionHours:12,
  screeningRiskHours:24,
  followupRiskHours:24,
  amReviewAttentionHours:4,
  amReviewRiskHours:8,
  clientFeedbackAttentionHours:24,
  clientFeedbackRiskHours:48,
  pipelineStagnationHours:24,
  requirementNoActivityHours:24,
  deadlineAttentionDays:3,
  deadlineRiskDays:1,
  minViablePipeline:2,
  alertCooldownMinutes:120,
  interviewReminderHours:24,
  offerActionHours:24,
  joiningActionDays:3
});

export function remaining(planned=0,completed=0){
  return Math.max(0,Number(planned||0)-Number(completed||0));
}

export function achievement(planned=0,completed=0){
  const p=Math.max(0,Number(planned||0));
  const c=Math.max(0,Number(completed||0));
  return p===0?0:Math.min(100,Math.round((c/p)*1000)/10);
}

export function targetState({planned=0,completed=0,hoursToCutoff=24,thresholds=DEFAULT_CONTROL_THRESHOLDS}={}){
  if(Number(planned||0)<=0||Number(completed||0)>=Number(planned||0))return 'ON_TRACK';
  if(hoursToCutoff<=thresholds.targetRiskHoursBeforeCutoff)return 'AT_RISK';
  if(hoursToCutoff<=thresholds.targetAttentionHoursBeforeCutoff)return 'ATTENTION';
  return 'ON_TRACK';
}

export function severityFor({blocked=false,atRisk=false,overdueHours=0,deadlineDays=null}={}){
  if(blocked||atRisk||Number(overdueHours||0)>=24||(deadlineDays!=null&&deadlineDays<=1))return 'URGENT';
  if(Number(overdueHours||0)>0||(deadlineDays!=null&&deadlineDays<=3))return 'ATTENTION';
  return 'INFO';
}

export function evaluateRequirementHealth(facts={},thresholds=DEFAULT_CONTROL_THRESHOLDS){
  if(facts.status==='ON_HOLD')return {health:'ON_HOLD',reasons:['REQUIREMENT_ON_HOLD']};
  const reasons=[];
  if(facts.explicitBlocker)reasons.push('EXPLICIT_BLOCKER');
  if((facts.dailyTarget||0)>0&&(facts.validSubmissionsToday||0)<(facts.dailyTarget||0)&&facts.hoursToCutoff<=thresholds.targetRiskHoursBeforeCutoff)reasons.push('TARGET_GAP_CUTOFF_NEAR');
  if((facts.pipelineCount||0)<thresholds.minViablePipeline&&(facts.deadlineDays==null||facts.deadlineDays<=thresholds.deadlineAttentionDays))reasons.push('INSUFFICIENT_PIPELINE');
  if((facts.overdueScreenings||0)>0)reasons.push('SCREENING_OVERDUE');
  if((facts.overdueFollowups||0)>0)reasons.push('FOLLOW_UP_OVERDUE');
  if((facts.amReviewBacklog||0)>0)reasons.push('AM_REVIEW_BACKLOG');
  if((facts.clientFeedbackBacklog||0)>0)reasons.push('CLIENT_FEEDBACK_DELAY');
  if(facts.deadlineDays!=null&&facts.deadlineDays<=thresholds.deadlineRiskDays)reasons.push('DEADLINE_IMMINENT');
  if((facts.hoursSinceActivity||0)>=thresholds.requirementNoActivityHours&&(facts.pipelineCount||0)===0)reasons.push('NO_RECENT_EXECUTION');

  if(reasons.includes('EXPLICIT_BLOCKER'))return {health:'BLOCKED',reasons};
  const urgent=new Set(['TARGET_GAP_CUTOFF_NEAR','DEADLINE_IMMINENT','INSUFFICIENT_PIPELINE']);
  if(reasons.some(r=>urgent.has(r))&&reasons.length>=2)return {health:'AT_RISK',reasons};
  if(reasons.length)return {health:'NEEDS_ATTENTION',reasons};
  return {health:'HEALTHY',reasons:[]};
}

export function deterministicAlertKey({ruleCode,entityType,entityId,ownerUserId=''}) {
  return [String(ruleCode||''),String(entityType||''),String(entityId||''),String(ownerUserId||'')].join('|');
}

export function nextOperationalActions(facts={}){
  const actions=[];
  if((facts.remainingTarget||0)>0)actions.push({code:'CLOSE_TARGET_GAP',text:`${facts.remainingTarget} more valid submission${facts.remainingTarget===1?'':'s'} required today.`,why:'Daily submission target is not yet achieved.'});
  if((facts.overdueScreenings||0)>0)actions.push({code:'COMPLETE_SCREENINGS',text:`${facts.overdueScreenings} screening action${facts.overdueScreenings===1?'':'s'} overdue.`,why:'Candidates are waiting in screening.'});
  if((facts.qualifiedWaiting||0)>0)actions.push({code:'SUBMIT_QUALIFIED',text:`${facts.qualifiedWaiting} qualified candidate${facts.qualifiedWaiting===1?'':'s'} waiting for internal submission.`,why:'Qualified candidates have not progressed to submission.'});
  if((facts.amReviewBacklog||0)>0)actions.push({code:'CLEAR_AM_BACKLOG',text:`${facts.amReviewBacklog} submission${facts.amReviewBacklog===1?'':'s'} waiting for AM review.`,why:'Internal submissions are ageing at the AM gate.'});
  if((facts.clientFeedbackBacklog||0)>0)actions.push({code:'FOLLOW_UP_CLIENT',text:`${facts.clientFeedbackBacklog} client submission${facts.clientFeedbackBacklog===1?'':'s'} awaiting feedback.`,why:'Client response has exceeded the configured feedback window.'});
  if((facts.pipelineCount||0)===0)actions.push({code:'BUILD_PIPELINE',text:'No viable candidate pipeline is available.',why:'The requirement has no active candidates in execution.'});
  return actions;
}

export function funnelCounts(rows=[]){
  const out={sourced:0,screened:0,qualified:0,internallySubmitted:0,amApproved:0,clientSubmitted:0,shortlisted:0,interviewed:0,offered:0,joined:0};
  for(const row of rows){
    const s=String(row.stage||row.state||'').toUpperCase();
    if(row.sourced||s)out.sourced++;
    if(row.screened||['SCREENING_COMPLETED','QUALIFIED','SUBMITTED','CLIENT_SUBMITTED','INTERVIEW','OFFER','JOINED'].includes(s))out.screened++;
    if(row.qualified||['QUALIFIED','SUBMITTED','CLIENT_SUBMITTED','INTERVIEW','OFFER','JOINED'].includes(s))out.qualified++;
    if(row.internallySubmitted)out.internallySubmitted++;
    if(row.amApproved)out.amApproved++;
    if(row.clientSubmitted)out.clientSubmitted++;
    if(row.shortlisted)out.shortlisted++;
    if(row.interviewed)out.interviewed++;
    if(row.offered)out.offered++;
    if(row.joined)out.joined++;
  }
  return out;
}

export function sourceConversion(rows=[]){
  const by=new Map();
  for(const r of rows){
    const source=String(r.source||'UNKNOWN').toUpperCase();
    if(!by.has(source))by.set(source,{source,candidates:0,qualified:0,clientSubmissions:0,interviews:0,offers:0,joinings:0});
    const x=by.get(source);x.candidates++;
    if(r.qualified)x.qualified++;
    if(r.clientSubmitted)x.clientSubmissions++;
    if(r.interviewed)x.interviews++;
    if(r.offered)x.offers++;
    if(r.joined)x.joinings++;
  }
  return [...by.values()];
}

export function workloadStatus({activeAssignments=0,dailyTarget=0,pendingScreenings=0,overdueFollowups=0,qualifiedWaiting=0}={}){
  const pressure=Number(activeAssignments||0)*2+Number(dailyTarget||0)*3+Number(pendingScreenings||0)*2+Number(overdueFollowups||0)*2+Number(qualifiedWaiting||0);
  if(pressure>=30)return 'HIGH_LOAD';
  if(pressure<=4)return 'LIGHT_LOAD';
  return 'BALANCED';
}

export function staffingConversionRatios(funnel={}){
  const rate=(a,b)=>Number(b)>0?Math.round(Number(a||0)/Number(b)*1000)/10:null;
  return {submissionToQualified:rate(funnel.clientSubmitted,funnel.qualified),interviewToSubmission:rate(funnel.interviewed,funnel.clientSubmitted),offerToInterview:rate(funnel.offered,funnel.interviewed),joinToOffer:rate(funnel.joined,funnel.offered)};
}
