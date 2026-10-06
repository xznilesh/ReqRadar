import { executeCandidateDeletion, findRetentionCandidates } from '../lib/retention-policy.js';

const execute=String(process.env.XZRECRUITER_RETENTION_EXECUTE||'').toLowerCase()==='true';
const limit=Math.max(1,Math.min(Number(process.env.XZRECRUITER_RETENTION_LIMIT||100),500));
const candidates=await findRetentionCandidates({limit});
let completed=0,blocked=0,failed=0;
for(const candidate of candidates){
  try{
    const result=await executeCandidateDeletion({
      agencyId:candidate.agency_id,
      candidateId:candidate.id,
      execute,
      retentionDays:candidate.retention_days
    });
    if(result?.blocked)blocked++;
    else if(result?.ok)completed++;
    else failed++;
    console.log('RETENTION_ITEM '+JSON.stringify({
      agency_id:candidate.agency_id,
      candidate_id:candidate.id,
      mode:execute?'EXECUTE':'DRY_RUN',
      ok:Boolean(result?.ok),
      blocked:Boolean(result?.blocked),
      run_id:result?.runId||null
    }));
  }catch(error){
    failed++;
    console.error('RETENTION_ITEM_ERROR '+JSON.stringify({
      agency_id:candidate.agency_id,
      candidate_id:candidate.id,
      code:String(error?.message||'retention_error').slice(0,120)
    }));
  }
}
console.log('RETENTION_EXECUTOR_RESULT '+JSON.stringify({
  mode:execute?'EXECUTE':'DRY_RUN',
  scanned:candidates.length,
  completed,
  blocked,
  failed
}));
if(failed>0)process.exit(2);
